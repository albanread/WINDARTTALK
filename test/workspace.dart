// WINDART — the consolidated interactive workspace IDE (T1). ONE persistent
// dartui application whose tab strip switches content: Workspace (editor + live
// Do It), Browser (VM class table via mirrors, class->members->source), Editor
// (edit a user class + Accept -> morphing hot-reload via the SQLite image), VM
// (live Dart_WorkspaceVmStats counters). Find/Docs/App/Help are placeholders; the
// Debug tab is deferred (T4). The app STAYS OPEN (event-driven) unless run with
// the `selftest` arg, which drives each tab and snapshots it.
import 'dart:win';
import 'dart:io';
import 'dart:async';
import 'dart:isolate';   // T4: spawn the debug target isolate
import 'dart:mirrors';
import 'dart:developer';   // C-harness: ext.dartui.send service extension (TCL GUI control)
import 'dart:convert';     // JSON for the extension reply envelope
import 'userlib:user';    // Stage 1: the live user library, served SYNCHRONOUSLY from
// the SQLite image by a C++ tag handler (dart_win32/windart_userlib.cc) — no scratch
// file, the DB is the source of truth. Single isolate: mirrors + a source import
// coexist since the scanner tolerates a leading BOM. Accept rewrites the `userlib`
// rows + hot-reloads (ReloadSources re-invokes the handler), morphing live instances.

// ── lexDart (verbatim from workspace.dart) — syntax runs for the source panes ─
final Set<String> _kw = new Set<String>.from(<String>[
  'abstract','as','assert','async','await','break','case','catch','class','const',
  'continue','default','deferred','do','dynamic','else','enum','export','extends',
  'external','factory','false','final','finally','for','get','if','implements',
  'import','in','is','library','new','null','operator','part','rethrow','return',
  'set','static','super','switch','sync','this','throw','true','try','typedef',
  'var','void','while','with','yield','bool','int','double','num']);
bool _dg(int c) => c >= 0x30 && c <= 0x39;
bool _hx(int c) => _dg(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
bool _up(int c) => c >= 0x41 && c <= 0x5A;
bool _al(int c) => _up(c) || (c >= 0x61 && c <= 0x7A);
bool _is0(int c) => _al(c) || c == 0x5F || c == 0x24;
bool _is1(int c) => _is0(c) || _dg(c);
List<int> lexDart(String s) {
  var o = <int>[]; var n = s.length, i = 0;
  while (i < n) {
    var c = s.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) { i++; continue; }
    if (c == 0x2F && i + 1 < n) {
      var d = s.codeUnitAt(i + 1);
      if (d == 0x2F) { var st = i; while (i < n && s.codeUnitAt(i) != 0x0A) i++; o..add(st)..add(i-st)..add(3); continue; }
      if (d == 0x2A) { var st = i; i += 2; while (i+1 < n && !(s.codeUnitAt(i)==0x2A && s.codeUnitAt(i+1)==0x2F)) i++; i = (i+1<n)?i+2:n; o..add(st)..add(i-st)..add(3); continue; }
    }
    if (c == 0x27 || c == 0x22) {
      var st = i; i++;
      while (i < n && s.codeUnitAt(i) != c && s.codeUnitAt(i) != 0x0A) { if (s.codeUnitAt(i)==0x5C) i++; i++; }
      if (i < n && s.codeUnitAt(i)==c) i++; o..add(st)..add(i-st)..add(2); continue;
    }
    if (_dg(c)) {
      var st = i;
      if (c==0x30 && i+1<n && (s.codeUnitAt(i+1)==0x78||s.codeUnitAt(i+1)==0x58)) { i+=2; while (i<n && _hx(s.codeUnitAt(i))) i++; }
      else { while (i<n) { var d=s.codeUnitAt(i); if (_dg(d)||d==0x2E||d==0x65||d==0x45||d==0x5F) i++; else break; } }
      o..add(st)..add(i-st)..add(4); continue;
    }
    if (_is0(c)) { var st=i; i++; while (i<n && _is1(s.codeUnitAt(i))) i++; var w=s.substring(st,i); var k=_kw.contains(w)?1:(_up(c)?5:0); o..add(st)..add(i-st)..add(k); continue; }
    i++;
  }
  return o;
}

// ── state ────────────────────────────────────────────────────────────────────
Ui ui;
int activeTab = 0;
// The pane (container) client size, refreshed on every resize (kind 7). Tab
// layouts are computed from these so content reflows to fill the window.
int paneW = 1084;
int paneH = 712;
List<String> content = <String>[];        // ids of the current tab's content widgets
Set<String> persistentWidgets = <String>{};  // widgets that survive a tab switch (tab strip etc.)
StringBuffer wsLog = new StringBuffer();
final tabNames = const ['Workspace','Browser','Editor','Find','Docs','App','Debug','VM','Help','Game','Inspect','ST Debug','Catalog'];

Map<String, ClassMirror> classMirrors = <String, ClassMirror>{};
List<String> classNames = <String>[];
List<String> members = <String>[];
String currentClass = '';

// ── Categorized browser (item 4): library -> class -> (vars|methods) -> source ─
List<String> libraryNames = <String>[];                       // dart:core, dart:io, ...
Map<String, List<String>> classesInLib = <String, List<String>>{};  // library -> classes
Map<String, String> libOfClass = <String, String>{};         // class -> owning library
String currentLib = '';
List<String> libClasses = <String>[];                         // classes in currentLib
List<String> brVars = <String>[];                             // currentClass variables
List<String> brMethods = <String>[];                          // currentClass methods
Map<String, String> _stMethSrc = <String, String>{};         // selector -> real ST method source (the fixed slicer's slices)

String imgPath;

// ── helpers ──────────────────────────────────────────────────────────────────
String wr(String s) => s.replaceAll('\n', '\r');   // Dart \n -> RichEdit break

// Selector from a method signature: 'from: a to: b' -> 'from:to:', '< x' -> '<',
// 'size' -> 'size'. A byte-for-byte mirror of _sigToSelector in language.dart, so
// a selected member row keys into the per-method source cache built from methodsrc.
String _sigToSelector(String sig) {
  if (!sig.contains(':')) return sig.trim().split(' ')[0];
  var out = new StringBuffer();
  for (var tok in sig.split(' ')) { if (tok.endsWith(':')) out.write(tok); }
  return out.toString();
}

void loadMembers(String cls) {
  members = <String>[];
  var cm = classMirrors[cls];
  if (cm == null) return;
  cm.declarations.forEach((sym, d) {
    var nm = MirrorSystem.getName(sym);
    if (nm.isEmpty || nm.startsWith('_')) return;
    var p = 'var ';
    if (d is MethodMirror) {
      if (d.isConstructor) { p = 'new '; }
      else if (d.isGetter) { p = 'get '; }
      else if (d.isSetter) { p = 'set '; }
      else { p = 'fn  '; }
    }
    members.add(p + nm);
  });
  members.sort();
}

// ── Mirror-driven declaration rendering (real signatures for VM classes) ──────
String _typeName(TypeMirror t) {
  if (t == null) return 'dynamic';
  try {
    var n = MirrorSystem.getName(t.simpleName);
    return n.isEmpty ? 'dynamic' : n;
  } catch (e) { return 'dynamic'; }
}

String _paramList(MethodMirror m) {
  try {
    // Group by kind so the WHOLE named set shares one {...} and the whole
    // optional-positional set shares one [...] — one brace per param produced
    // invalid Dart, e.g. Duration({int days}, {int hours}, ...).
    var req = <String>[], opt = <String>[], named = <String>[];
    for (var p in m.parameters) {
      var pn = MirrorSystem.getName(p.simpleName);
      var s = '${_typeName(p.type)} $pn';
      if (p.isNamed) named.add(s);
      else if (p.isOptional) opt.add(s);
      else req.add(s);
    }
    var parts = <String>[];
    parts.addAll(req);
    if (opt.isNotEmpty) parts.add('[${opt.join(', ')}]');
    if (named.isNotEmpty) parts.add('{${named.join(', ')}}');
    return parts.join(', ');
  } catch (e) { return ''; }
}

String _methodDecl(String cls, MethodMirror m) {
  var name = MirrorSystem.getName(m.simpleName);
  var stat = m.isStatic ? 'static ' : '';
  if (m.isConstructor) {
    var cn = '';
    try { cn = MirrorSystem.getName(m.constructorName); } catch (e) {}
    var full = cn.isEmpty ? cls : '$cls.$cn';
    return '$full(${_paramList(m)});';
  }
  var ret = _typeName(m.returnType);
  if (m.isGetter) return '$stat$ret get $name;';
  if (m.isSetter) {
    var base = name.endsWith('=') ? name.substring(0, name.length - 1) : name;
    return '${stat}set $base(${_paramList(m)});';
  }
  if (m.isOperator) return '$stat$ret operator $name(${_paramList(m)});';
  return '$stat$ret $name(${_paramList(m)});';
}

// The full class declaration from the live VM class mirror: real field types,
// constructor/accessor/method signatures (no bodies — the VM has no source for
// snapshot classes), grouped and sorted. Used by the Browser/Docs/Editor source
// panes for VM classes.
String classSketch(String name) {
  var cm = classMirrors[name];
  var sb = new StringBuffer();
  sb.writeln('// $name  (declaration from the live VM class mirror — signatures, no bodies)');
  if (cm == null) { sb.writeln('class $name {\n}'); return sb.toString(); }
  var sup = '';
  try {
    if (cm.superclass != null) sup = ' extends ' + MirrorSystem.getName(cm.superclass.simpleName);
  } catch (e) {}
  sb.writeln('class $name$sup {');
  var vars = <String>[], ctors = <String>[], acc = <String>[], meths = <String>[];
  cm.declarations.forEach((sym, d) {
    try {
      var nm = MirrorSystem.getName(sym);
      if (nm.isEmpty || nm.startsWith('_')) return;
      if (d is VariableMirror) {
        var stat = d.isStatic ? 'static ' : '';
        var fin = d.isFinal ? 'final ' : '';
        vars.add('  $stat$fin${_typeName(d.type)} $nm;');
      } else if (d is MethodMirror) {
        var line = '  ' + _methodDecl(name, d);
        if (d.isConstructor) ctors.add(line);
        else if (d.isGetter || d.isSetter) acc.add(line);
        else meths.add(line);
      }
    } catch (e) { /* one declaration's mirror threw — skip it, keep the rest */ }
  });
  vars.sort(); ctors.sort(); acc.sort(); meths.sort();
  if (vars.isNotEmpty)  { sb.writeln('  // fields');       for (var l in vars)  sb.writeln(l); }
  if (ctors.isNotEmpty) { sb.writeln('  // constructors'); for (var l in ctors) sb.writeln(l); }
  if (acc.isNotEmpty)   { sb.writeln('  // accessors');    for (var l in acc)   sb.writeln(l); }
  if (meths.isNotEmpty) { sb.writeln('  // methods');      for (var l in meths) sb.writeln(l); }
  sb.writeln('}');
  return sb.toString();
}

// ── On-disk SDK source (real bodies, not just mirror signatures) ──────────────
// The mirror browser can only show signatures — the running VM keeps no source
// for its snapshot classes. But the 1.24.3 SDK sources ARE on disk (the build's
// extracted tree, or the pristine quarry), so we read the real class/method text
// straight from the .dart files. First existing root wins, per file.
// ── WINDARTARM: repo-relative path roots (was a hard-pinned E: drive) ────────
// Everything below is derived from where THIS script lives, so the IDE runs
// from any checkout on any machine. Expected layout:
//   <workRoot>/WINDARTTALK/test/workspace.dart   <- this file
//   <workRoot>/WINDARTTALK/{workspace,demos}/    <- repo content
//   <workRoot>/{tree,sdk-1.24.3}/                <- extracted tree + quarry
// Snapshot/PNG output goes to $WINDART_OUT, else <workRoot>/shots.
String _dirOf(String p) {
  var i = p.lastIndexOf('/'), j = p.lastIndexOf(r'\');
  var k = i > j ? i : j;
  return k > 0 ? p.substring(0, k) : p;
}

final String scriptDir = _dirOf(Platform.script.toFilePath());  // <repo>/test
final String repoRoot = _dirOf(scriptDir);                      // <repo>
final String workRoot = _dirOf(repoRoot);                       // <workRoot>
final String outDir = () {
  var o = Platform.environment['WINDART_OUT'];
  var d = (o != null && o.trim().isNotEmpty) ? o.trim() : '$workRoot/shots';
  try { new Directory(d).createSync(recursive: true); } catch (e) { }
  return d;
}();

// A PNG path inside the output dir.
String outPng(String name) => '$outDir/$name.png';

// On-disk SDK source roots: the extracted build tree first, then the pristine
// quarry. First existing root wins, per file.
final List<String> _sdkRoots = <String>[
  '$workRoot/tree/sdk/lib',
  '$workRoot/sdk-1.24.3/sdk/lib',
];

String _libDir(String lib) {
  if (lib == null || !lib.startsWith('dart:')) return '';
  var d = lib.substring(5);
  if (d.startsWith('_')) d = d.substring(1);       // dart:_internal -> internal
  return d;
}

// Skip a Dart string literal (single/triple, escapes) at i; return the index past it.
int _skipStr(String s, int i) {
  var n = s.length, q = s.codeUnitAt(i);
  var triple = i + 2 < n && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q;
  if (triple) {
    i += 3;
    while (i + 2 < n && !(s.codeUnitAt(i) == q && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q)) {
      if (s.codeUnitAt(i) == 0x5C) i++;
      i++;
    }
    return (i + 2 < n) ? i + 3 : n;
  }
  i++;
  while (i < n && s.codeUnitAt(i) != q && s.codeUnitAt(i) != 0x0A) {
    if (s.codeUnitAt(i) == 0x5C) i++;
    i++;
  }
  return (i < n && s.codeUnitAt(i) == q) ? i + 1 : i;
}

// Index of the '}' matching the '{' at `open`, skipping comments and strings.
int _matchBrace(String s, int open) {
  var n = s.length, depth = 0, i = open;
  while (i < n) {
    var c = s.codeUnitAt(i);
    if (c == 0x2F && i + 1 < n) {                    // '/'
      var d = s.codeUnitAt(i + 1);
      if (d == 0x2F) { i += 2; while (i < n && s.codeUnitAt(i) != 0x0A) i++; continue; }
      if (d == 0x2A) { i += 2; while (i + 1 < n && !(s.codeUnitAt(i) == 0x2A && s.codeUnitAt(i + 1) == 0x2F)) i++; i += 2; continue; }
    }
    if (c == 0x27 || c == 0x22) { i = _skipStr(s, i); continue; }
    if (c == 0x7B) depth++;                          // {
    else if (c == 0x7D) { depth--; if (depth == 0) return i; }   // }
    i++;
  }
  return -1;
}

// The real on-disk source of `cls` from its dart: library file, or '' if not
// found (a native class with no .dart, or the source tree is absent).
String sdkClassSource(String cls) {
  var lib = libOfClass[cls];
  var sub = _libDir(lib);
  if (sub.isEmpty) return '';
  var decl = new RegExp('^[ \\t]*(abstract[ \\t]+)?class[ \\t]+' + cls + '[ \\t\\r\\n<{]', multiLine: true);
  for (var root in _sdkRoots) {
    var dir = new Directory('$root/$sub');
    if (!dir.existsSync()) continue;
    for (var ent in dir.listSync()) {
      if (ent is! File) continue;
      var f = ent as File;
      var path = f.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart')) continue;
      String text;
      try { text = f.readAsStringSync(); } catch (e) { continue; }
      var m = decl.firstMatch(text);
      if (m == null) continue;
      var start = m.start;
      while (start < text.length) {
        var cc = text.codeUnitAt(start);
        if (cc == 0x20 || cc == 0x09 || cc == 0x0A || cc == 0x0D) start++; else break;
      }
      var open = text.indexOf('{', start);
      if (open < 0) continue;
      var close = _matchBrace(text, open);
      if (close < 0) continue;
      return '// $lib  ::  $cls        (real source: $path)\n' + text.substring(start, close + 1) + '\n';
    }
  }
  return '';
}

// The search anchor for a member declaration string (get/set/operator/name).
String _memberAnchor(String decl) {
  var d = decl.replaceAll(';', '').trim();
  var paren = d.indexOf('(');
  var head = (paren < 0 ? d : d.substring(0, paren)).trim();
  var gi = head.indexOf(' get ');
  if (gi >= 0) return 'get ' + head.substring(gi + 5).trim();
  var si = head.indexOf(' set ');
  if (si >= 0) return 'set ' + head.substring(si + 5).trim();
  var op = head.indexOf('operator ');
  if (op >= 0) return head.substring(op).trim();
  var parts = head.split(new RegExp('\\s+'));
  return parts.isEmpty ? '' : parts[parts.length - 1];
}

// Best-effort: just one member's real source, sliced from its class file.
String sdkMemberSource(String cls, String decl) {
  var full = sdkClassSource(cls);
  if (full.isEmpty) return '';
  var anchor = _memberAnchor(decl);
  if (anchor.isEmpty) return '';
  var idx = full.indexOf(anchor);
  if (idx < 0) return '';
  var ls = full.lastIndexOf('\n', idx);
  var start = ls < 0 ? 0 : ls + 1;
  var brace = full.indexOf('{', idx);
  var semi = full.indexOf(';', idx);
  int end;
  if (brace >= 0 && (semi < 0 || brace < semi)) {
    var close = _matchBrace(full, brace);
    end = (close < 0) ? (semi < 0 ? full.length - 1 : semi) : close;
  } else {
    end = (semi < 0) ? full.length - 1 : semi;
  }
  var head = '// $cls  ::  ' + decl.replaceAll(';', '').trim() + '   (real source)\n';
  return head + full.substring(start, end + 1) + '\n';
}

Db openImage() {
  var db = new Db.open(imgPath);
  db.exec('CREATE TABLE IF NOT EXISTS classes(name TEXT PRIMARY KEY, source TEXT)');
  return db;
}

// The user class source shown in the Editor tab: from the image if present, else
// a default. (Persisted by Accept; loaded over the snapshot at boot.)
String userClassSource() {
  var db = openImage();
  var rows = db.query('SELECT source FROM classes WHERE name = ?', ['Counter']);
  db.close();
  if (rows.isNotEmpty && rows[0][0].toString().isNotEmpty) return rows[0][0].toString();
  return 'class Counter {\n  int n = 0;\n  int step = 1;\n  Counter bump() { n = n + step; return this; }\n}';
}

// ── tab content builders ─────────────────────────────────────────────────────
void track(String id) => content.add(id);

void clearContent() {
  // Remove EVERY non-persistent widget, not just the ones the per-tab `content` list
  // captured. A user app's build() (e.g. the Calculator) may create widgets that were
  // never tracked; if they are not destroyed here they remain as live Win32 child
  // windows behind the next tab and repaint on hover. Iterating ui.widgetIds (kept
  // accurate by ui.remove dropping the ticket-map entry) removes all of them.
  for (var id in ui.widgetIds.toList()) {
    if (!persistentWidgets.contains(id)) ui.remove(id);
  }
  content.clear();
}

void buildWorkspace() {
  var W = paneW, H = paneH;
  var edH = ((H - 58) * 0.40).round();     // editor ~40% of the pane height
  var doitY = 58 + edH + 8;
  var outlY = doitY + 34;
  var outY = outlY + 22;
  var outH = H - outY - 10;
  ui.label('ws_lbl', text: 'Workspace   -   type Dart OR Smalltalk, click Do It   (bilingual: 25 sqrt,  (2+3)*7,  st> 6*7)', frame: <int>[12, 36, W - 24, 18]); track('ws_lbl');
  ui.editor('ws_editor', text: '(2 + 3) * 7', frame: <int>[12, 58, W - 24, edH]); track('ws_editor');
  ui.button('ws_doit', title: 'Do It', frame: <int>[12, doitY, 100, 28], onClick: doIt); track('ws_doit');
  ui.label('ws_hint', text: '(result appended to Output below)', frame: <int>[124, doitY + 4, 500, 18]); track('ws_hint');
  ui.label('ws_outl', text: 'Output', frame: <int>[12, outlY, 200, 18]); track('ws_outl');
  ui.editor('ws_output', frame: <int>[12, outY, W - 24, outH]); track('ws_output');
  ui.set('ws_output', {'text': wr(wsLog.toString())});
}

// ── C1: bilingual Do It. The Smalltalk/Dart LANGUAGE isolate (workspace/
// language.dart — MACDART's bilingual brain, running verbatim on windart) is
// spawned at boot; Do It routes through it over the wire, so `25 sqrt` and
// `(2 + 3) * 7` share one workspace with no language toggle.
SendPort _lang; // the language isolate's command port
Future ask(String verb, arg) {
  var reply = new ReceivePort();
  _lang.send([verb, arg, reply.sendPort]);
  return reply.first;
}
void spawnLanguage() {
  final langSrc = '$repoRoot/workspace/language.dart';
  var scratch = new File(Directory.systemTemp.path + r'\ws_language.dart');
  try {
    scratch.writeAsStringSync(new File(langSrc).readAsStringSync());
  } catch (e) {
    print('LANG: cannot stage language.dart: $e');
    return;
  }
  var rp = new ReceivePort();
  rp.listen((msg) {
    if (_lang == null && msg is SendPort) {
      _lang = msg;
      print('LANG: bilingual language isolate up');
      _loadStWorld();   // C2: import the ST world so its classes are browsable
    } else if (msg is List && msg.isNotEmpty && msg[0] == 'tr') {
      wsLog.writeln(msg[1].toString()); // Smalltalk Transcript -> Output pane
    } else if (msg is List && msg.length >= 4 && msg[0] == 'appui') {
      _appApply(msg[3]);   // C4: a running app's widget batch -> dart:win controls
    } else if (_stGameActive && msg is List && msg.isNotEmpty &&
               (msg[0] == 'port' || msg[0] == 'draw' || msg[0] == 'done')) {
      _gameFrame(msg);   // C5: ST game frames -> the D3D11 game pane
    }
  });
  Isolate.spawnUri(scratch.uri, <String>[scratch.path, '', '', ''], rp.sendPort);
}

// ── C2: browse the Smalltalk world. On boot the world is imported into the
// language isolate; its classes appear under a "smalltalk" library in the
// Browser, and selecting one fetches its real .mst source + method list over
// the wire (dart:mirrors can't see ST classes — they have no TokenStream).
Set<String> _stClasses = new Set<String>();
bool _stWorldLoaded = false;
// The Smalltalk world corpus is NOT tracked in this repo (see .gitignore:
// "the MACDART reference clone (its own repo; obtain from github separately)").
// Point WINDART_ST_WORLD at a Windows-ported world to load one; the import
// degrades gracefully when the directory is absent. NOTE the MACDARTV1
// dartui-workspace branch carries the *Mac* world (97 .mst) — that is reference
// material for porting, not a drop-in (cf. the galaxigans commit, which went
// x64-ASM -> Mac-ST -> Windows-ST). galaxigans.mst IS in this repo and loads.
final String _stWorldDir = () {
  var w = Platform.environment['WINDART_ST_WORLD'];
  if (w != null && w.trim().isNotEmpty) return w.trim();
  return '$repoRoot/st/world';          // where a Windows world would live
}();
final String _stGalaxigans = '$repoRoot/demos/galaxigans.mst';

void _loadStWorld() {
  if (_stWorldLoaded || _lang == null) return;
  _stWorldLoaded = true;
  ask('stimport', _stWorldDir).then((imp) {
    print('ST-WORLD: ' + imp.toString());
    // Galaxigans — the x64-assembler arcade shooter, rewritten in Smalltalk. A
    // filed-in game: import it AFTER the world it needs (GamePane, Sound), then
    // enumerate classes so it is browsable + launchable.
    ask('stimport', _stGalaxigans).then((gx) => print('ST-GAME galaxigans: ' + gx.toString()));
    ask('classes', '').then((raw) {
      var names =
          (raw is List) ? raw.map((e) => e.toString()).toList() : <String>[];
      names.sort();
      _stClasses = new Set<String>.from(names);
      if (!libraryNames.contains('smalltalk')) libraryNames.insert(0, 'smalltalk');
      classesInLib['smalltalk'] = names;
      for (var n in names) libOfClass[n] = 'smalltalk';
      print('ST-WORLD: ' + names.length.toString() + ' Smalltalk classes browsable');
      if (ui.ticketOf('br_libs') != null) {
        ui.set('br_libl', {'text': 'Libraries (${libraryNames.length})'});
        ui.set('br_libs', {'rows': libraryNames.length});
        ui.commit();
      }
    });
  });
}

// Browse a Smalltalk class: members + real source come from the language
// isolate over the wire (async), not from dart:mirrors.
Future _browseStClass(String cls) async {
  currentLib = 'smalltalk';
  libClasses = classesInLib['smalltalk'] ?? <String>[];
  currentClass = cls;
  ui.set('br_ll', {'text': 'Classes (${libClasses.length})'});
  ui.set('br_classes', {'rows': libClasses.length});
  ui.set('br_source', {'text': '"loading ' + cls + ' ..."'});
  ui.commit();
  var mems = await ask('members', cls);
  brVars = <String>[];
  brMethods = (mems is List) ? mems.map((e) => e.toString()).toList() : <String>[];
  brMethods.sort();
  // Cache every method's REAL source in one bulk round-trip, so selecting a method
  // shows its whole body (the fixed slicer's slice), not just the heading. methodsrc
  // streams "<i|c> <selector>\n<source>\n" per method; we key by selector, the
  // same key our _sigToSelector(brMethods[r]) computes on selection.
  _stMethSrc = <String, String>{};
  var bulk = (await ask('methodsrc', cls)).toString();
  for (var block in bulk.split(new String.fromCharCode(0x1d))) {
    if (block.isEmpty) continue;
    var nl = block.indexOf('\n');
    if (nl < 0) continue;
    var head = block.substring(0, nl).trim();            // "i selector" | "c selector"
    var sp = head.indexOf(' ');
    var sel = sp < 0 ? head : head.substring(sp + 1);
    _stMethSrc[sel] = block.substring(nl + 1);           // full method source
  }
  ui.set('br_vl', {'text': 'Variables - instance (0)'});
  ui.set('br_ml', {'text': 'Methods - instance (${brMethods.length})'});
  ui.set('br_vars', {'rows': 0});
  ui.set('br_meths', {'rows': brMethods.length});
  var src = await ask('classsrc', cls);
  ui.set('br_source', {'text': wr(src.toString())});
  ui.commit();
  print('BROWSE ST: ' + cls + ' (' + brMethods.length.toString() +
      ' methods, ' + _stMethSrc.length.toString() + ' sources cached)');
}

void doIt() {
  var sel = ui.editorSelection('ws_editor');
  var code = sel[2].toString().replaceAll('\r', ' ').trim();
  if (code.isEmpty) return;
  if (_lang == null) {
    print('DOIT: $code => (language isolate not ready)');
    return;
  }
  ask('doit', code).then((result) {
    wsLog.writeln('$code   =>   $result');
    print('DOIT: $code => $result');
    ui.set('ws_output', {'text': wr(wsLog.toString())});
    ui.commit();
  });
}

// ── C-harness: the ext.dartui.send service extension — LIVE GUI control over the
// VM service (dartui --observe, ws://127.0.0.1:8181) for the TCL snapshot
// regression suite (tcl/dartui.tcl). `ui <verb> <arg>`: doit/snap/tab/type/editor
// are handled here; any OTHER verb forwards straight to the language isolate
// (classes/members/classsrc/accept/apps/stgame/...), so TCL drives the whole
// bilingual backend without a per-verb stub here.
Future<String> handle(String line) async {
  line = line.trim();
  var sp = line.indexOf(' ');
  var verb = sp < 0 ? line : line.substring(0, sp);
  var arg = sp < 0 ? '' : line.substring(sp + 1);
  switch (verb) {
    case 'ping':
      return 'pong';
    case 'snap':
      var p = arg.trim().isEmpty ? outPng('ui') : arg.trim();
      wsSnapshotFull(p);
      return 'ok:' + p;
    case 'tab':
      switchTab(int.parse(arg.trim(), onError: (_) => 0));
      ui.commit();
      return 'ok';
    case 'type':
      ui.set('ws_editor', {'text': arg});
      ui.commit();
      return 'ok';
    case 'editor':
      var s = ui.editorSelection('ws_editor');
      return s.length > 2 ? s[2].toString() : '';
    case 'browse':
      switchTab(1);
      var c = arg.trim();
      if (_stClasses.contains(c)) {
        await _browseStClass(c);
        return 'browsed ST ' + c;
      }
      browseToClass(c);
      return 'browsed ' + c;
    case 'selmeth':
      // Select a method in the Browser's member list (drives selectBrMethod, the
      // per-method source view). Arg is a 0-based index, or a selector/signature.
      var a = arg.trim();
      var idx = int.parse(a, onError: (_) => -1);
      if (idx < 0) {
        for (var i = 0; i < brMethods.length; i++) {
          if (brMethods[i] == a || _sigToSelector(brMethods[i]) == a) { idx = i; break; }
        }
      }
      if (idx < 0 || idx >= brMethods.length) return 'ERR no method ' + a;
      selectBrMethod(idx);
      return 'selected ' + brMethods[idx];
    case 'edclass':
      switchTab(2);
      loadEditorClass(arg.trim());
      currentEditClass = arg.trim();
      return 'editing ' + arg.trim();
    case 'edset':
      ui.set('ed_source', {'text': arg});
      ui.commit();
      return 'ok';
    case 'edaccept':
      accept();
      return 'accept fired for ' + currentEditClass;
    case 'apprun':
      switchTab(5);
      _appName = arg.trim();
      ui.set('app_status', {'text': 'running: $_appName'});
      ui.commit();
      return (await ask('apprun', [_appName, paneW.toDouble(), paneH.toDouble()])).toString();
    case 'appstop':
      var r = (_lang == null) ? 'ok' : (await ask('appstop', '')).toString();
      _appName = '';
      return r;
    case 'click':
      if (_lang == null) return '(no lang)';
      await ask('appevent', [arg.trim(), 'click', '']);
      return 'clicked ' + arg.trim();
    case 'stgames':
      return (await ask('stgames', '')).toString();
    case 'stgame':
      switchTab(9);
      startStGame(arg.trim());
      return 'st game ' + arg.trim();
    case 'gpsnap':
      var gp = arg.trim().isEmpty ? outPng('gp') : arg.trim();
      return 'gpsnap: ' + gpSnap(gp);   // read the D3D offscreen pixels to a PNG
    case 'doit':
      if (_lang == null) return '(language isolate not ready)';
      return (await ask('doit', arg)).toString();
    case 'uinspect':                       // drive the Inspector tab + snapshot
      if (activeTab != 10) switchTab(10);
      ui.set('insp_expr', {'text': arg.trim()}); ui.commit();
      await doInspect(arg.trim());
      return 'inspected ' + arg.trim() + ' -> ' + inspClass + ' (' + inspIvars.length.toString() + ' ivars)';
    case 'uinspsel':
      _showInspSlot(int.parse(arg.trim(), onError: (_) => 0));
      return 'slot ' + inspSel.toString();
    case 'uinspdive':
      await inspectDive();
      return 'dived -> ' + inspClass;
    case 'uinspback':
      await inspectBack();
      return 'back -> ' + inspClass;
    case 'usdebug':                        // drive the ST Debug tab + snapshot
      if (activeTab != 11) switchTab(11);
      ui.set('sdb_expr', {'text': arg.trim()}); ui.commit();
      await debugStRun(arg.trim());
      return sdbError.isEmpty
          ? 'ok -> ' + sdbResult
          : 'raised -> ' + sdbError.split('\n')[0] + ' (' + sdbFrames.length.toString() + ' ST frames)';
    case 'usdbsel':
      _showStFrame(int.parse(arg.trim(), onError: (_) => -1));
      return 'frame ' + sdbSel.toString();
    case 'ufind':                          // drive the Find tab (bilingual find)
      if (activeTab != 3) switchTab(3);
      ui.set('fd_q', {'text': arg.trim()}); ui.commit();
      await doFind();
      return 'find "' + arg.trim() + '" -> ' + findResults.length.toString() + ' matches';
    case 'usenders':                       // drive the Find tab (senders)
      if (activeTab != 3) switchTab(3);
      ui.set('fd_q', {'text': arg.trim()}); ui.commit();
      await doSenders();
      return 'senders "' + arg.trim() + '" -> ' + findResults.length.toString() + ' classes';
    case 'ufindopen':
      openFindResult(int.parse(arg.trim(), onError: (_) => -1));
      return 'opened ' + arg.trim();
    case 'ucatalog':                       // open + refresh the Catalog tab
      if (activeTab != 12) switchTab(12); else await _catRefresh();
      return 'catalog: ' + catApps.length.toString() + ' apps, ' + catGames.length.toString() + ' games, ' + catDemos.length.toString() + ' demos';
    case 'ucatload':                       // rolling: import an .mst, refresh
      if (activeTab != 12) switchTab(12);
      ui.set('cat_path', {'text': arg.trim()}); ui.commit();
      await _catLoad(arg.trim());
      return 'loaded -> ' + catApps.length.toString() + ' apps, ' + catGames.length.toString() + ' games';
    case 'ucatapp':
      _catRunApp(catApps.indexOf(arg.trim()));
      return 'run app ' + arg.trim();
    case 'ucatgame':
      var gi = -1;
      for (var i = 0; i < catGames.length; i++) { if (catGames[i][0] == arg.trim()) { gi = i; break; } }
      _catRunGame(gi);
      return 'run game ' + arg.trim();
    default:
      if (_lang == null) return '(language isolate not ready)';
      return (await ask(verb, arg)).toString();
  }
}

void registerDartuiExt() {
  registerExtension('ext.dartui.send',
      (String method, Map<String, String> params) async {
    var line = params['line'];
    if (line == null) {
      return new ServiceExtensionResponse.error(
          ServiceExtensionResponse.kInvalidParams,
          "ext.dartui.send needs a 'line' parameter");
    }
    try {
      if (params['nowait'] == 'true') {
        handle(line).catchError((e) {});
        return new ServiceExtensionResponse.result(
            JSON.encode(<String, String>{'reply': 'started'}));
      }
      var reply = await handle(line);
      return new ServiceExtensionResponse.result(
          JSON.encode(<String, String>{'reply': reply.toString()}));
    } catch (e) {
      return new ServiceExtensionResponse.result(
          JSON.encode(<String, String>{'reply': 'ERR: ' + e.toString()}));
    }
  });
}

// Smalltalk-style member side: 0 = instance (non-static), 1 = class (static
// members + constructors/factories). The instance/class toggle filters the
// Variables + Methods panes.
int browserSide = 0;
String sideName() => browserSide == 0 ? 'instance' : 'class';

// The classic drill-down: Libraries | Classes | (Variables / Methods) | Source.
// Categories are dart:mirrors libraries; each column narrows the selection.
void buildBrowser() {
  var W = paneW, H = paneH;
  var listH = H - 68;
  var libX = 12,           libW = 176;
  var clsX = libX + libW + 8, clsW = 196;
  var memX = clsX + clsW + 8, memW = 236;
  var srcX = memX + memW + 8, srcW = W - srcX - 12;
  var memTop = 82;                                // member lists start below the toggle row
  var memListH = listH - 24;
  var varH = ((memListH - 22) * 0.42).round();    // variables pane ~top 42%
  var methLblY = memTop + varH + 4;
  var methY = memTop + varH + 22;
  var methH = memListH - varH - 22;               // methods pane fills the rest

  if (currentLib.isEmpty && libraryNames.isNotEmpty) {   // default category
    currentLib = libraryNames.contains('dart:core') ? 'dart:core' : libraryNames[0];
    libClasses = classesInLib[currentLib] ?? <String>[];
  }

  ui.label('br_libl', text: 'Libraries (${libraryNames.length})', frame: <int>[libX, 36, libW, 18]); track('br_libl');
  ui.list('br_libs', frame: <int>[libX, 58, libW, listH],
      rowCount: () => libraryNames.length, cellAt: (r) => libraryNames[r], onSelect: selectLibrary); track('br_libs');

  ui.label('br_ll', text: 'Classes (${libClasses.length})', frame: <int>[clsX, 36, clsW, 18]); track('br_ll');
  ui.list('br_classes', frame: <int>[clsX, 58, clsW, listH],
      rowCount: () => libClasses.length, cellAt: (r) => libClasses[r], onSelect: selectLibClass); track('br_classes');
  // A user-draggable divider between the Libraries and Classes panes (item 5).
  ui.splitter('br_split', orientation: 'vertical', frame: <int>[libX + libW + 2, 58, 6, listH],
      between: <String>['br_libs', 'br_classes']); track('br_split');

  var sn = sideName();
  ui.label('br_vl', text: currentClass.isEmpty ? 'Variables ($sn)' : 'Variables - $sn (${brVars.length})', frame: <int>[memX, 36, memW, 18]); track('br_vl');
  // Smalltalk-style instance/class side toggle over the Variables + Methods panes.
  var halfW = ((memW - 4) / 2).round();
  ui.button('br_inst', title: 'instance', frame: <int>[memX, 58, halfW, 22], onClick: () => setBrowserSide(0)); track('br_inst');
  ui.button('br_cls', title: 'class', frame: <int>[memX + halfW + 4, 58, memW - halfW - 4, 22], onClick: () => setBrowserSide(1)); track('br_cls');
  ui.list('br_vars', frame: <int>[memX, memTop, memW, varH],
      rowCount: () => brVars.length, cellAt: (r) => brVars[r], onSelect: selectBrVar); track('br_vars');
  ui.label('br_ml', text: currentClass.isEmpty ? 'Methods ($sn)' : 'Methods - $sn (${brMethods.length})', frame: <int>[memX, methLblY, memW, 18]); track('br_ml');
  ui.list('br_meths', frame: <int>[memX, methY, memW, methH],
      rowCount: () => brMethods.length, cellAt: (r) => brMethods[r], onSelect: selectBrMethod); track('br_meths');

  ui.label('br_sl', text: 'Source', frame: <int>[srcX, 36, srcW, 18]); track('br_sl');
  ui.editor('br_source', frame: <int>[srcX, 58, srcW, listH]); track('br_source');

  if (currentClass.isNotEmpty) {                 // restore member panes after a rebuild
    loadVarsMethods(currentClass);
    ui.set('br_vl', {'text': 'Variables - ${sideName()} (${brVars.length})'});
    ui.set('br_ml', {'text': 'Methods - ${sideName()} (${brMethods.length})'});
    ui.set('br_vars', {'rows': brVars.length});
    ui.set('br_meths', {'rows': brMethods.length});
    var real = sdkClassSource(currentClass);
    var src = real.isNotEmpty ? real : classSketch(currentClass);
    ui.set('br_source', {'text': wr(src)});
  }
}

// Split a class's declarations into variable + method rows (short signatures).
void loadVarsMethods(String cls) {
  brVars = <String>[]; brMethods = <String>[];
  var cm = classMirrors[cls];
  if (cm == null) return;
  var wantStatic = browserSide == 1;             // class side = static members + ctors/factories
  cm.declarations.forEach((sym, d) {
    try {
      var nm = MirrorSystem.getName(sym);
      if (nm.isEmpty || nm.startsWith('_')) return;
      if (d is VariableMirror) {
        if (d.isStatic != wantStatic) return;
        brVars.add((d.isStatic ? 'static ' : '') + (d.isFinal ? 'final ' : '') + _typeName(d.type) + ' ' + nm);
      } else if (d is MethodMirror) {
        var classSide = d.isStatic || d.isConstructor;
        if (classSide != wantStatic) return;
        brMethods.add(_methodDecl(cls, d));
      }
    } catch (e) {}
  });
  brVars.sort(); brMethods.sort();
}

// Instance/Class toggle: re-filter the current class's member panes by side.
void setBrowserSide(int side) {
  if (browserSide == side) return;
  browserSide = side;
  if (currentClass.isNotEmpty) loadVarsMethods(currentClass);
  ui.set('br_vl', {'text': currentClass.isEmpty ? 'Variables (${sideName()})' : 'Variables - ${sideName()} (${brVars.length})'});
  ui.set('br_ml', {'text': currentClass.isEmpty ? 'Methods (${sideName()})' : 'Methods - ${sideName()} (${brMethods.length})'});
  ui.set('br_vars', {'rows': brVars.length});
  ui.set('br_meths', {'rows': brMethods.length});
  ui.commit();
  print('BROWSE side=${sideName()} -> ${brVars.length} vars, ${brMethods.length} methods');
}

// Category pane: pick a library -> repopulate the Classes pane, clear the rest.
void selectLibrary(int r) {
  if (r < 0 || r >= libraryNames.length) return;
  currentLib = libraryNames[r];
  libClasses = classesInLib[currentLib] ?? <String>[];
  currentClass = ''; brVars = <String>[]; brMethods = <String>[];
  ui.set('br_ll', {'text': 'Classes (${libClasses.length})'});
  ui.set('br_classes', {'rows': libClasses.length});
  ui.set('br_vl', {'text': 'Variables'});
  ui.set('br_ml', {'text': 'Methods'});
  ui.set('br_vars', {'rows': 0});
  ui.set('br_meths', {'rows': 0});
  ui.set('br_source', {'text': ''});
  ui.commit();
  print('LIB: $currentLib -> ${libClasses.length} classes');
}

// Classes pane: pick a class within the current library.
void selectLibClass(int r) {
  if (r < 0 || r >= libClasses.length) return;
  var cls = libClasses[r];
  browseToClass(cls);
  var flat = classNames.indexOf(cls);
  if (flat >= 0 && !_browseNav) _browseRecord(flat);
  print('BROWSE: class $cls -> ${brVars.length} vars, ${brMethods.length} methods');
}

// Navigate to a class by NAME: sync the category + class panes, load its vars +
// methods, show its declaration. The shared entry point for the Classes pane,
// Find jumps, and toolbar Back/Forward/Home.
void browseToClass(String cls) {
  if (_stClasses.contains(cls)) { _browseStClass(cls); return; }
  var lib = libOfClass[cls];
  if (lib != null && (lib != currentLib || libClasses.isEmpty)) {
    currentLib = lib;
    libClasses = classesInLib[lib] ?? <String>[];
    ui.set('br_ll', {'text': 'Classes (${libClasses.length})'});
    ui.set('br_classes', {'rows': libClasses.length});
  }
  currentClass = cls;
  loadVarsMethods(cls);
  ui.set('br_vl', {'text': 'Variables - ${sideName()} (${brVars.length})'});
  ui.set('br_ml', {'text': 'Methods - ${sideName()} (${brMethods.length})'});
  ui.set('br_vars', {'rows': brVars.length});
  ui.set('br_meths', {'rows': brMethods.length});
  var real = sdkClassSource(cls);                  // real on-disk bodies if we have them
  var src = real.isNotEmpty ? real : classSketch(cls);
  ui.set('br_source', {'text': wr(src)});
  ui.commit();
  ui.applySpans('br_source', lexDart(src));
}

// Member panes -> the Source pane shows the selected member's declaration.
void selectBrVar(int r) {
  if (r < 0 || r >= brVars.length) return;
  var src = '// $currentLib  ::  $currentClass\n${brVars[r]};\n';
  ui.set('br_source', {'text': wr(src)}); ui.commit();
  ui.applySpans('br_source', lexDart(src));
  print('BROWSE: var ${brVars[r]}');
}
void selectBrMethod(int r) {
  if (r < 0 || r >= brMethods.length) return;
  var sig = brMethods[r];
  if (_stClasses.contains(currentClass)) {
    // Smalltalk: show the method's WHOLE body from the slice cache (populated in
    // _browseStClass over the wire). Before this, the ST path fell through to the
    // Dart-disk reader below, which returns nothing for ST classes — so the pane
    // showed only the heading. Key by selector, exactly as the cache is built.
    var src = _stMethSrc[_sigToSelector(sig)];
    if (src == null || src.trim().isEmpty) {
      src = '"' + currentClass + ' >> ' + sig + '  (source unavailable)"\n' + sig + '\n';
    }
    ui.set('br_source', {'text': wr(src)}); ui.commit();
    ui.applySpans('br_source', lexDart(src));   // no ST lexer yet; matches the editor
    print('BROWSE ST: method ' + sig);
    return;
  }
  var real = sdkMemberSource(currentClass, sig);   // real body if on disk (Dart)
  var src = real.isNotEmpty ? real : '// $currentLib  ::  $currentClass\n$sig\n';
  ui.set('br_source', {'text': wr(src)}); ui.commit();
  ui.applySpans('br_source', lexDart(src));
  print('BROWSE: method $sig');
}

// Flat-index entry (toolbar Back/Forward/Home history, Find jumps).
void selectClass(int r) {
  if (r < 0 || r >= classNames.length) return;
  browseToClass(classNames[r]);
  if (!_browseNav) _browseRecord(r);
  print('BROWSE: class ${classNames[r]}');
}

// ── Browser navigation (toolbar Home / Back / Forward) ────────────────────────
// A back/forward stack of class indices, cursor at the current position. A fresh
// selectClass (user click, Find jump) pushes; Back/Forward move the cursor and
// re-select WITHOUT re-recording (guarded by _browseNav).
List<int> browseHistory = <int>[];
int browseCursor = -1;
bool _browseNav = false;

void _browseRecord(int idx) {
  if (browseCursor >= 0 && browseCursor < browseHistory.length &&
      browseHistory[browseCursor] == idx) return;          // ignore a repeat
  if (browseCursor < browseHistory.length - 1) {
    browseHistory = browseHistory.sublist(0, browseCursor + 1);   // drop the forward tail
  }
  browseHistory.add(idx);
  browseCursor = browseHistory.length - 1;
}

void _browseGo(int idx) {                    // navigate without recording
  if (activeTab != 1) switchTab(1);
  _browseNav = true;
  selectClass(idx);
  _browseNav = false;
}

void browseBack() {
  if (activeTab != 1) switchTab(1);
  if (browseCursor > 0) { browseCursor--; _browseGo(browseHistory[browseCursor]); }
  print('NAV: back -> cursor $browseCursor/${browseHistory.length - 1}');
}

void browseForward() {
  if (activeTab != 1) switchTab(1);
  if (browseCursor < browseHistory.length - 1) {
    browseCursor++; _browseGo(browseHistory[browseCursor]);
  }
  print('NAV: forward -> cursor $browseCursor/${browseHistory.length - 1}');
}

void browseHome() {                          // Browser tab, reset to the top class
  if (activeTab != 1) switchTab(1);
  if (classNames.isNotEmpty) selectClass(0);   // records (default _browseNav == false)
  print('NAV: home -> ${classNames.isEmpty ? "" : classNames[0]}');
}

// The Editor is now pick-a-class-then-edit: a class-selector dropdown lists the
// user classes stored in the image plus the live VM classes (via mirrors).
String currentEditClass = 'Counter';
List<String> editorClassList = <String>[];

void buildEditorClassList() {
  var seen = new Set<String>();
  editorClassList = <String>[];
  var db = openImage();
  var rows = db.query('SELECT name FROM classes ORDER BY name', const []);
  db.close();
  for (var r in rows) { var n = r[0].toString(); if (seen.add(n)) editorClassList.add(n); }
  if (seen.add('Counter')) editorClassList.insert(0, 'Counter');     // always offer Counter
  for (var n in classNames) { if (seen.add(n)) editorClassList.add(n); }   // then VM classes
  var st = _stClasses.toList()..sort();
  for (var n in st) { if (seen.add(n)) editorClassList.add(n); }           // C3: Smalltalk classes
}

String editorSourceFor(String cls) {
  var db = openImage();
  var isUser = userClassNames.contains(cls);
  if (isUser) db.exec('CREATE TABLE IF NOT EXISTS userlib(name TEXT PRIMARY KEY, source TEXT)', const []);
  var rows = db.query('SELECT source FROM ' + (isUser ? 'userlib' : 'classes') + ' WHERE name = ?', [cls]);
  db.close();
  if (rows.isNotEmpty && rows[0][0].toString().isNotEmpty) return rows[0][0].toString();
  if (cls == 'Counter') {
    return 'class Counter {\n  int n = 0;\n  Counter bump() { n = n + 1; return this; }\n}';
  }
  if (classMirrors.containsKey(cls)) {
    loadMembers(cls);
    var real = sdkClassSource(cls);
    return real.isNotEmpty ? real : classSketch(cls);
  }
  return 'class $cls {\n}';
}

void loadEditorClass(String cls) {
  currentEditClass = cls;
  if (_stClasses.contains(cls)) {   // C3: Smalltalk class — real source over the wire
    ui.set('ed_status', {'text': 'loading Smalltalk $cls ...'});
    ui.commit();
    ask('classsrc', cls).then((src) {
      ui.set('ed_source', {'text': wr(src.toString())});
      ui.set('ed_status', {'text': 'editing $cls   (Smalltalk — Accept recompiles it live)'});
      ui.commit();
    });
    print('EDITOR: selected ST class $cls');
    return;
  }
  var src = editorSourceFor(cls);
  ui.set('ed_source', {'text': wr(src)});
  ui.set('ed_status', {'text': 'editing $cls'});
  ui.commit();
  ui.applySpans('ed_source', lexDart(src));
  print('EDITOR: selected class $cls');
}

void buildEditor() {
  if (editorClassList.isEmpty) buildEditorClassList();
  var W = paneW, H = paneH;
  var srcH = H - 92 - 100;                 // editor fills, leaving room for the footer
  var acceptY = 92 + srcH + 10;
  ui.label('ed_lbl', text: 'Editor   -   pick a class, read/edit its source; Accept saves it to the SQLite image', frame: <int>[12, 36, W - 24, 18]); track('ed_lbl');
  ui.label('ed_cl_lbl', text: 'Class:', frame: <int>[12, 62, 48, 18]); track('ed_cl_lbl');
  ui.popup('ed_class', items: editorClassList, frame: <int>[64, 58, 320, 260],
      onSelect: (i) { if (i >= 0 && i < editorClassList.length) loadEditorClass(editorClassList[i]); }); track('ed_class');
  ui.editor('ed_source', frame: <int>[12, 92, W - 24, srcH]); track('ed_source');
  ui.button('ed_accept', title: 'Accept', frame: <int>[12, acceptY, 100, 28], onClick: accept); track('ed_accept');
  ui.button('ed_revert', title: 'Revert', frame: <int>[118, acceptY, 90, 28], onClick: revert); track('ed_revert');   // W3: undo to prior version
  ui.label('ed_status', text: 'editing $currentEditClass', frame: <int>[216, acceptY + 4, W - 228, 18]); track('ed_status');
  ui.label('ed_note', text: 'Accept writes the user class to the SQLite image (userlib) + hot-reloads: live instances MORPH in place (state kept, new fields added). A C++ tag handler serves the source from the image - no file. Survives restart.', frame: <int>[12, acceptY + 36, W - 24, 18]); track('ed_note');
  ui.label('ed_img', text: 'image: $imgPath', frame: <int>[12, acceptY + 62, W - 24, 18]); track('ed_img');
  var src = editorSourceFor(currentEditClass);
  ui.set('ed_source', {'text': wr(src)});
  var idx = editorClassList.indexOf(currentEditClass);
  if (idx >= 0) ui.set('ed_class', {'index': idx});
  ui.commit();
  ui.applySpans('ed_source', lexDart(src));
}

// ── Stage 1: the live user library (DB-served, single isolate) ────────────────
// The user classes live in the image's `userlib` table. `import 'userlib:user'`
// (top) is served SYNCHRONOUSLY from that table by a C++ tag handler
// (dart_win32/windart_userlib.cc). Accept writes the edited source to `userlib`
// and hot-reloads; ReloadSources re-invokes the handler, re-reads the image, and
// morphs live instances in place. No scratch file — the DB is the source of truth.
final List<String> userClassNames = <String>['Counter'];   // the live user classes
dynamic liveCounter;                                        // a live instance to morph

// User-class source lives in the image's `userlib` table; the C++ userlib: tag
// handler (windart_userlib.cc) serves it to `import 'userlib:user'` — no file.

// Read the live instance's state via eval in the root library (sees userlib's Counter).
String liveState() {
  var n = wsEval('liveCounter == null ? "-" : liveCounter.n');
  // inc() is a METHOD, so it re-links on every morph and tracks the source version
  // (a field would keep its value across re-morphs — state preservation).
  var inc = wsEval('liveCounter == null ? "" : liveCounter.inc()');
  var s = 'live Counter.n=' + n;
  if (!inc.startsWith('ERR') && inc.isNotEmpty) s = s + '  inc()=' + inc;
  return s;
}

void accept() {
  var sel = ui.editorSelection('ed_source');
  var src = sel[2].toString().replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  // C3: a Smalltalk edit (a known ST class, or source shaped `X subclass: Y [`)
  // recompiles LIVE through the language isolate — morphing, image-backed, with
  // an ERR (rollback-safe) on a bad parse. dart:mirrors never sees it.
  if (_stClasses.contains(currentEditClass) ||
      new RegExp(r'\bsubclass:\s*\w+\s*\[').hasMatch(src)) {
    ui.set('ed_status', {'text': 'accepting Smalltalk $currentEditClass ...'});
    ui.commit();
    ask('accept', src).then((r) {
      var rs = r.toString();
      var ok = !rs.startsWith('ERR');
      ui.set('ed_status', {'text': (ok ? 'Accepted ' : 'REJECTED ') + '$currentEditClass  (Smalltalk): $rs'});
      ui.commit();
      _stClasses.add(currentEditClass);
      print('ACCEPT ST: $currentEditClass -> $rs');
    });
    return;
  }
  var isUser = userClassNames.contains(currentEditClass);
  // Validate-before-save (syntax-check-first): compile the edit in isolation; only
  // clean source is written to the image + reloaded, so the reload never sees
  // uncompilable source (a bad reload's finalize would kill the isolate). Logical/
  // runtime errors are a separate matter — found by running, not by this scan.
  if (isUser) {
    var err = wsCheckSyntax(src, currentEditClass);
    if (err.isNotEmpty) {
      // Dart reports "'usercheck:N': error: line L pos P: msg\n  <src line>\n  ^".
      // Strip the internal URI to the bare location + message, and highlight the
      // offending line in the editor (SetFocus + select via editorSelectLine).
      var loc = new RegExp(r'line (\d+) pos (\d+): (.*)').firstMatch(err);
      var head = (loc != null)
          ? 'line ${loc.group(1)} pos ${loc.group(2)}: ${loc.group(3)}'
          : err.replaceAll('\r', ' ').replaceAll('\n', ' ');
      ui.set('ed_status', {'text': 'REJECTED - $currentEditClass: $head'});
      ui.commit();
      if (loc != null) ui.editorSelectLine('ed_source', int.parse(loc.group(1)) - 1);
      print('ACCEPT REJECTED (syntax): $currentEditClass: $head');
      return;   // do NOT write the image or reload
    }
  }
  var db = openImage();
  if (isUser) {
    db.exec('CREATE TABLE IF NOT EXISTS userlib(name TEXT PRIMARY KEY, source TEXT)', const []);
    // W3: version the outgoing source (multi-level undo). Before overwriting, save
    // what the image currently holds for this class, so Revert can step back through
    // the history of accepted (and therefore gate-passed, compilable) versions.
    db.exec('CREATE TABLE IF NOT EXISTS versions(id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'ts TEXT, kind TEXT, name TEXT, source TEXT, label TEXT)', const []);
    var cur = db.query('SELECT source FROM userlib WHERE name = ?', [currentEditClass]);
    if (cur != null && cur.isNotEmpty && cur[0][0].toString().isNotEmpty) {
      db.exec('INSERT INTO versions(ts, kind, name, source, label) VALUES(?, ?, ?, ?, ?)',
          [new DateTime.now().toIso8601String(), 'userlib', currentEditClass, cur[0][0], 'pre-accept']);
    }
    db.exec('INSERT OR REPLACE INTO userlib(name, source) VALUES(?, ?)', [currentEditClass, src]);
  } else {
    db.exec('INSERT OR REPLACE INTO classes(name, source) VALUES(?, ?)', [currentEditClass, src]);
  }
  db.close();
  wsRequestUiReload();   // ReloadSources re-invokes the userlib: handler -> re-reads the image -> morph
  ui.set('ed_status', {'text': 'Accept: wrote image' + (isUser ? ' (userlib) -> reloading (morph)...' : ' -> reloading...')});
  ui.commit();
  new Timer(new Duration(milliseconds: 350), () {
    var st = wsUiReloadStatus();
    var live = isUser ? ('   ' + liveState()) : '';
    ui.set('ed_status', {'text': 'Accepted $currentEditClass  (reload: "$st")$live'});
    ui.commit();
    print('ACCEPT: $currentEditClass reload="$st"$live');
  });
}

// W3: how many older versions of a user class are on the undo stack.
int versionCount(String cls) {
  var db = openImage();
  var r = db.query('SELECT COUNT(*) FROM versions WHERE kind = ? AND name = ?', ['userlib', cls]);
  db.close();
  if (r == null || r.isEmpty) return 0;   // versions table not created yet
  return int.parse(r[0][0].toString());
}

// W3: revert the current user class to its most recent prior version and hot-reload
// (morph). Each Revert pops one entry off the undo stack, so repeated Reverts step
// further back. Only versions that were Accepted (and so passed the syntax gate) are
// on the stack, so the reload never sees uncompilable source.
void revert() {
  if (!userClassNames.contains(currentEditClass)) {
    ui.set('ed_status', {'text': 'Revert: $currentEditClass is not a live user class'});
    ui.commit();
    return;
  }
  var db = openImage();
  var v = db.query('SELECT id, source FROM versions WHERE kind = ? AND name = ? ORDER BY id DESC LIMIT 1',
      ['userlib', currentEditClass]);
  if (v == null || v.isEmpty) {
    db.close();
    ui.set('ed_status', {'text': 'Revert: no earlier version of $currentEditClass'});
    ui.commit();
    print('REVERT: $currentEditClass has no history');
    return;
  }
  var id = v[0][0];
  var oldSrc = v[0][1].toString();
  db.exec('INSERT OR REPLACE INTO userlib(name, source) VALUES(?, ?)', [currentEditClass, oldSrc]);
  db.exec('DELETE FROM versions WHERE id = ?', [id]);   // consume this undo step
  db.close();
  ui.set('ed_source', {'text': wr(oldSrc)});
  ui.commit();
  ui.applySpans('ed_source', lexDart(oldSrc));
  wsRequestUiReload();   // morph live instances to the reverted version
  ui.set('ed_status', {'text': 'Reverting $currentEditClass -> reloading (morph)...'});
  ui.commit();
  new Timer(new Duration(milliseconds: 350), () {
    var st = wsUiReloadStatus();
    var live = '   ' + liveState();
    ui.set('ed_status', {'text': 'Reverted $currentEditClass  (reload: "$st")$live   [${versionCount(currentEditClass)} older]'});
    ui.commit();
    print('REVERT: $currentEditClass reload="$st"$live older=${versionCount(currentEditClass)}');
  });
}

// W5: regenerate the boot snapshot from the VM's OWN gen_snapshot, then bake it into
// the image as a new versioned blob (W3 @prev preserved). The world rebuilds its own
// snapshot — no C++ build, no external tooling. Today this reproduces the core
// snapshot (the core libs are fixed in the binary); it becomes edit-capturing once
// core/app source moves into the image. Closes the DB-world loop:
// gen_snapshot -> .bin -> versioned blob -> boot.
void recreateSnapshot() {
  var exe = Platform.resolvedExecutable;                 // ...\dartui.exe
  var slash = exe.lastIndexOf('\\');
  if (slash < 0) slash = exe.lastIndexOf('/');
  var dir = exe.substring(0, slash + 1);                 // exe dir + trailing slash
  var gen = dir + 'gen_snapshot.exe';
  var vmBin = dir + 'vm_isolate_snapshot.bin';
  var isoBin = dir + 'isolate_snapshot.bin';
  print('RECREATE: running $gen (--snapshot_kind=core)');
  var r = Process.runSync(gen, <String>['--ignore_unrecognized_flags',
      '--snapshot_kind=core', '--vm_snapshot_data=' + vmBin,
      '--isolate_snapshot_data=' + isoBin]);
  print('RECREATE: gen_snapshot exit=${r.exitCode}');
  if (r.exitCode != 0) {
    print('RECREATE: FAILED: ${r.stderr}');
    return;
  }
  print('RECREATE: ' + wsBakeSnapshot());                // fresh .bin -> versioned blob
}

final vmLabels = const ['heap new used (B)','heap new capacity (B)','heap old used (B)',
  'heap old capacity (B)','scavenges (new GC)','mark-sweeps (old GC)',
  'functions compiled','functions optimized','generated code bytes'];

void buildVM() {
  ui.label('vm_lbl', text: 'VM   -   live counters (Dart_WorkspaceVmStats, refreshed every second)', frame: <int>[12, 36, 700, 18]); track('vm_lbl');
  for (var i = 0; i < vmLabels.length; i++) {
    ui.label('vm_k$i', text: vmLabels[i] + ':', frame: <int>[24, 70 + i * 30, 260, 18]); track('vm_k$i');
    ui.label('vm_v$i', text: '...', frame: <int>[300, 70 + i * 30, 320, 18]); track('vm_v$i');
  }
  refreshVM();
}

void refreshVM() {
  if (activeTab != 7) return;
  var stats = wsVmStats();
  for (var i = 0; i < vmLabels.length && i < stats.length; i++) {
    ui.set('vm_v$i', {'text': stats[i].toString()});
  }
  ui.commit();
}

num _statVal(v) { try { return num.parse(v.toString()); } catch (e) { return 0; } }

// Feed the toolbar's live metric graph — total heap used (MB), sampled every second
// (always, regardless of the active tab, since the toolbar is always visible).
void pushToolbarMetric() {
  var s = wsVmStats();
  if (s == null || s.length < 9) return;
  var usedMB = (_statVal(s[0]) + _statVal(s[2])) / 1048576.0;
  var compiled = _statVal(s[6]).toInt();
  var codeK = (_statVal(s[8]) / 1024.0).round();
  wsPushToolbarMetric(usedMB.toDouble(),
      'heap ${usedMB.toStringAsFixed(1)} MB     compiled $compiled     code ${codeK}K');
}

// ── Find tab (T2): substring over classes + members -> jump to Browser ────────
List<String> findResults = <String>[];              // display rows
List<List<String>> findMeta = <List<String>>[];     // [className, isSt('1'/'0'), selector]
void buildFind() {
  var W = paneW, H = paneH;
  ui.label('fd_lbl', text: 'Find   -   classes + methods across the Dart VM AND the Smalltalk world.   Senders = classes whose source references the name.', frame: <int>[12, 36, W - 24, 18]); track('fd_lbl');
  ui.field('fd_q', text: '', frame: <int>[12, 58, 300, 24], onEnter: () { doFind(); }); track('fd_q');
  ui.button('fd_go', title: 'Find', frame: <int>[320, 57, 80, 26], onClick: () { doFind(); }); track('fd_go');
  ui.button('fd_send', title: 'Senders', frame: <int>[408, 57, 96, 26], onClick: () { doSenders(); }); track('fd_send');
  ui.label('fd_rl', text: 'Matches (click a result to open it in the Browser)', frame: <int>[12, 92, W - 24, 18]); track('fd_rl');
  ui.list('fd_results', frame: <int>[12, 114, W - 24, H - 124],
      rowCount: () => findResults.length, cellAt: (r) => r < findResults.length ? findResults[r] : '', onSelect: openFindResult); track('fd_results');
}

void _paintFind(String q, String mode) {
  ui.set('fd_rl', {'text': mode + ' "$q":  ${findResults.length} matches   (click a result to open it in the Browser)'});
  ui.set('fd_results', {'rows': findResults.length});
  ui.commit();
  print('FIND($mode): "$q" -> ${findResults.length}');
}

// Bilingual find: Dart VM classes/members via mirrors (they carry no ST class),
// PLUS the Smalltalk world via the server-side `find` verb (name + method sig).
Future doFind() async {
  var q = ui.textOf('fd_q').trim();
  findResults = <String>[]; findMeta = <List<String>>[];
  if (q.isEmpty) { _paintFind(q, 'Find'); return; }
  var lq = q.toLowerCase();
  for (var c in classNames) {
    if (c.toLowerCase().contains(lq)) { findResults.add('Dart class    ' + c); findMeta.add(<String>[c, '0', '']); }
  }
  for (var c in classNames) {
    var cm = classMirrors[c];
    cm.declarations.forEach((sym, d) {
      var nm = MirrorSystem.getName(sym);
      if (nm.isNotEmpty && !nm.startsWith('_') && nm.toLowerCase().contains(lq)) {
        findResults.add('Dart          ' + c + '.' + nm); findMeta.add(<String>[c, '0', nm]);
      }
    });
    if (findResults.length > 400) break;
  }
  if (_lang != null) {
    var st = await ask('find', q);
    if (st is List) {
      for (var e in st) {
        if (e is! List || e.isEmpty) continue;
        var cls = e[0].toString();
        if (!_stClasses.contains(cls)) continue;      // Dart side already covered above
        var sel = e.length > 1 ? e[1].toString() : '';
        var side = e.length > 2 ? e[2].toString() : 'instance';
        findResults.add('Smalltalk     ' + cls + (sel.isEmpty ? '' : (side == 'class' ? ' class>>' : ' >> ') + sel));
        findMeta.add(<String>[cls, '1', sel]);
      }
    }
  }
  _paintFind(q, 'Find');
}

// Senders: every class whose SOURCE references the name (a selector or a class).
Future doSenders() async {
  var q = ui.textOf('fd_q').trim();
  findResults = <String>[]; findMeta = <List<String>>[];
  if (q.isEmpty || _lang == null) { _paintFind(q, 'Senders'); return; }
  var s = await ask('senders', q);
  if (s is List) {
    for (var e in s) {
      var cls = (e is List && e.isNotEmpty) ? e[0].toString() : e.toString();
      var isSt = _stClasses.contains(cls) ? '1' : '0';
      findResults.add((isSt == '1' ? 'Smalltalk     ' : 'Dart          ') + cls);
      findMeta.add(<String>[cls, isSt, '']);
    }
  }
  _paintFind(q, 'Senders');
}

void openFindResult(int r) {
  if (r < 0 || r >= findMeta.length) return;
  var cls = findMeta[r][0];
  var isSt = findMeta[r][1] == '1';
  switchTab(1);            // Browser
  if (isSt) {
    _browseStClass(cls);
  } else {
    var idx = classNames.indexOf(cls);
    if (idx >= 0) selectClass(idx);
  }
  print('FIND: open ' + (isSt ? 'ST ' : 'Dart ') + cls);
}

// ── App tab (T2): a user app (Calculator) materialized in the app pane ────────
// Inlined (NOT imported — a source-loaded library + dart:mirrors crashes the VM,
// see T1). It uses only the Ui view-server API; its onClick handlers do the
// arithmetic and ui.set the display, which _winDispatch auto-commits.
class Calculator {
  var acc = 0.0;
  var pending;
  var display = '0';
  var fresh = true;
  build(u) {
    u.field('d', text: display, frame: <double>[8.0, 40.0, 272.0, 32.0], align: 'right', readOnly: true);
    var keys = ['7','8','9','/','4','5','6','*','1','2','3','-','0','.','=','+'];
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      u.button('k$k', title: k,
          frame: <double>[8.0 + (i % 4) * 68.0, 80.0 + (i ~/ 4) * 46.0, 64.0, 40.0],
          onClick: () => press(k, u));
    }
    u.button('kC', title: 'C', frame: <double>[8.0 + 4 * 68.0, 80.0, 64.0, 40.0], onClick: () => reset(u));
    u.label('hint', text: 'a live user app: buttons run Dart in the workspace (App-pane model)', frame: <int>[8, 274, 500, 16]);
  }
  press(String k, u) {
    if (k == '.' || (k.compareTo('0') >= 0 && k.compareTo('9') <= 0)) {
      if (fresh) { display = (k == '.') ? '0.' : k; fresh = false; }
      else if (k != '.' || !display.contains('.')) { display = display + k; }
    } else if (k == '=') { acc = _apply(_value()); display = _format(acc); pending = null; fresh = true; }
    else { acc = _apply(_value()); display = _format(acc); pending = k; fresh = true; }
    u.set('d', {'text': display});
    print('CALC: key $k -> display $display');
  }
  reset(u) { acc = 0.0; pending = null; display = '0'; fresh = true; u.set('d', {'text': display}); }
  _value() => double.parse(display, (_) => 0.0);
  _apply(double v) {
    if (pending == null) return v;
    if (pending == '+') return acc + v;
    if (pending == '-') return acc - v;
    if (pending == '*') return acc * v;
    if (pending == '/') return (v == 0.0) ? 0.0 : acc / v;
    return v;
  }
  _format(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
    return v.toString();
  }
}
Calculator calc;
// ── C4: run a Smalltalk (or Dart) app in the App pane. The language isolate
// hosts the app instance; its widgets arrive as ['appui', name, gen, cmds] and
// materialize here on dart:win. Button/field callbacks post back as
// ['appevent', id, kind, value] and fire the app's ST (or Dart) handler block.
String _appName = '';
List<String> _appWidgets = <String>[];

List<int> _frameOf(p) {
  var f = (p is Map) ? p['frame'] : null;
  if (f is List && f.length >= 4) return f.map((e) => (e as num).toInt()).toList();
  return <int>[12, 92, 240, 24];
}

void _appApply(List batch) {
  if (activeTab != 5) return;   // only materialize while the App pane is showing
  for (var cmd in batch) {
    if (cmd is! List || cmd.isEmpty) continue;
    var op = cmd[0].toString();
    if (op == 'clear') {
      _appWidgets.clear();
    } else if (op == 'title') {
      ui.set('app_status', {'text': 'running: $_appName   -   ${cmd.length > 1 ? cmd[1] : ''}'});
    } else if (op == 'set' && cmd.length >= 3 && cmd[2] is Map) {
      ui.set(cmd[1].toString(), cmd[2]);
    } else if (op == 'add' && cmd.length >= 4) {
      var kind = cmd[1].toString(), id = cmd[2].toString(), p = cmd[3];
      var frame = _frameOf(p);
      var text = (p is Map && p['text'] != null) ? p['text'].toString() : '';
      var title = (p is Map && p['title'] != null) ? p['title'].toString() : '';
      if (_appWidgets.contains(id)) {   // re-`add` of a live widget = update it in place
        var props = <String, dynamic>{};
        if (text.isNotEmpty) props['text'] = text;
        if (title.isNotEmpty) props['title'] = title;
        if (props.isNotEmpty) ui.set(id, props);
        continue;
      }
      _appWidgets.add(id);
      switch (kind) {
        case 'label': ui.label(id, text: text, frame: frame); break;
        case 'field': case 'secure': ui.field(id, text: text, frame: frame); break;
        case 'button':
          ui.button(id, title: title, frame: frame, onClick: () => _sendAppEvent(id, 'click', '')); break;
        case 'checkbox':
          ui.checkbox(id, title: title, checked: (p is Map && p['value'] == true), frame: frame); break;
        case 'popup':
          var items = (p is Map && p['items'] is List) ? p['items'] : const [];
          ui.popup(id, items: items, frame: frame, onSelect: (i) => _sendAppEvent(id, 'select', '$i')); break;
        default: ui.label(id, text: '[$kind $id]', frame: frame);
      }
      track(id);
    }
  }
  ui.commit();
}

void _sendAppEvent(String id, String kind, value) {
  if (_lang == null) return;
  ask('appevent', [id, kind, value.toString()]);   // fire the ST/Dart handler
  print('APP-EVENT: $id/$kind');
}

void buildApp() {
  var W = paneW;
  ui.label('app_lbl', text: 'App   -   run a live app:   ui apprun <StClass>   (a class with  build: ui  [ ... ])', frame: <int>[12, 40, W - 24, 18]); track('app_lbl');
  ui.label('app_status', text: _appName.isEmpty ? 'no app running' : 'running: $_appName', frame: <int>[12, 64, W - 24, 18]); track('app_status');
  if (_appName.isNotEmpty && _lang != null) {
    ask('appbuild', [_appName, paneW.toDouble(), paneH.toDouble()]);   // re-render after a tab rebuild
  }
}

// ── Docs tab (T2): a class/member reference from the VM class table ───────────
void buildDocs() {
  var W = paneW, H = paneH;
  var listH = H - 68;
  var detX = 324, detW = W - detX - 12;
  ui.label('dc_lbl', text: 'Docs   -   the VM class reference (select a class to see its members)', frame: <int>[12, 36, W - 24, 18]); track('dc_lbl');
  ui.list('dc_classes', frame: <int>[12, 58, 300, listH],
      rowCount: () => classNames.length, cellAt: (r) => classNames[r], onSelect: selectDocsClass); track('dc_classes');
  ui.label('dc_dl', text: 'Members', frame: <int>[detX, 36, detW, 18]); track('dc_dl');
  ui.editor('dc_detail', frame: <int>[detX, 58, detW, listH]); track('dc_detail');
}
void selectDocsClass(int r) {
  if (r < 0 || r >= classNames.length) return;
  var cls = classNames[r];
  loadMembers(cls);
  var src = classSketch(cls);
  ui.set('dc_dl', {'text': 'Members of $cls (${members.length})'});
  ui.set('dc_detail', {'text': wr(src)});
  ui.commit();
  ui.applySpans('dc_detail', lexDart(src));
}

// ── Help tab (T2): about / usage / keybindings ────────────────────────────────
void buildHelp() {
  var W = paneW, H = paneH;
  ui.label('hp_lbl', text: 'Help   -   WINDART workspace', frame: <int>[12, 36, W - 24, 18]); track('hp_lbl');
  ui.editor('hp_text', frame: <int>[12, 58, W - 24, H - 68]); track('hp_text');
  var help =
      'WINDART  -  a live Windows Dart workspace (Dart 1.24.3 JIT, native Win32 + Direct2D)\n'
      '\n'
      'TABS\n'
      '  Workspace  -  type a Dart expression, click Do It to EVALUATE it against the live VM\n'
      '                (Dart_EvaluateExpr). The result is appended to the Output pane.\n'
      '  Browser    -  browse the running VM\'s classes (via dart:mirrors): Classes -> Members\n'
      '                -> Source (a declaration sketch, syntax-highlighted).\n'
      '  Editor     -  edit a user class source; Accept persists it to the SQLite image\n'
      '                (%USERPROFILE%\\.windart\\workspace.sqlite, survives restart) + hot-reloads.\n'
      '  Find       -  substring search over class and member names; click a result to open it.\n'
      '  Docs       -  the class reference: pick a class, read its members.\n'
      '  App        -  a live user app (Calculator) materialized in the app pane; its buttons\n'
      '                are Dart closures that run in the workspace and update the display.\n'
      '  VM         -  live VM counters (Dart_WorkspaceVmStats): heap, GC, JIT compile stats.\n'
      '  Debug      -  the vm-service debugger (deferred to a later slice).\n'
      '\n'
      'GESTURES\n'
      '  Do It   -  evaluate the selection (or the whole editor) as a Dart expression, live.\n'
      '  Accept  -  commit a class definition: persist to the image + hot-reload; live instances\n'
      '             morph across a class-shape change (keep state, gain new fields).\n'
      '\n'
      'This whole IDE is ONE dartui.exe process: the VM you are inspecting is the VM running it.';
  ui.set('hp_text', {'text': wr(help)});
}

// ── Debug tab (T4): the in-process debugger ───────────────────────────────────
// Debugs a spawned target isolate (debug_target.dart) via the classic embedder
// debug API: set a line breakpoint, run, PAUSE at it, show the call stack + the
// current line marked in the source, evaluate an expression in the paused frame,
// step, and resume to completion. The step buttons pick the step mode (over/into/
// out) or plain resume; each Run drives one scripted breakpoint->pause->stack->
// eval->step->resume session (the buttons re-run with that mode).
const int kDbgBreakLine = 15;          // `var acc = 1;` in debug_target.dart
String dbgSource = '';                 // the target's source (read at build)
List<String> dbgStackLines = <String>[];
Timer dbgPollTimer;
bool dbgRunning = false;
int dbgPausedLine = -1;

String _dbgTargetPath() {
  try {
    var dir = new File.fromUri(Platform.script).parent.path;
    return dir + Platform.pathSeparator + 'debug_target.dart';
  } catch (e) { return 'debug_target.dart'; }
}

void _dbgLoadSource() {
  try { dbgSource = new File(_dbgTargetPath()).readAsStringSync(); }
  catch (e) { dbgSource = '// could not read debug_target.dart: $e'; }
}

// Render the source with a '*' on the breakpoint line and '>' on the paused line.
String _dbgRenderSource() {
  var lines = dbgSource.split('\n');
  var sb = new StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    var n = i + 1;
    var mark = (n == dbgPausedLine) ? '>' : (n == kDbgBreakLine ? '*' : ' ');
    sb.write(mark);
    sb.write(n < 10 ? '  $n| ' : (n < 100 ? ' $n| ' : '$n| '));
    sb.write(lines[i]);
    sb.write('\n');
  }
  return sb.toString();
}

void buildDebug() {
  if (dbgSource.isEmpty) _dbgLoadSource();
  dbgPausedLine = -1;
  // Responsive layout: source editor fills the left column down to the button row
  // (pinned to the bottom); the stack / eval / transcript fill the right column.
  var W = paneW, H = paneH;
  var leftW = (W * 0.56).round();
  var rightX = leftW + 24, rightW = W - rightX - 12;
  var btnY = H - 44;                       // button row + status pinned to the bottom
  var srcH = btnY - 84 - 8;                // editor: y=84 down to just above the buttons

  ui.label('db_lbl', text: 'Debug   -   in-process debugger (classic embedder API) on a spawned target isolate',
      frame: <int>[12, 36, W - 24, 18]); track('db_lbl');
  ui.label('db_target', text: 'target: debug_target.dart      breakpoint: line $kDbgBreakLine (int factorial)      * = breakpoint   > = paused line',
      frame: <int>[12, 58, W - 24, 18]); track('db_target');

  ui.editor('db_src', frame: <int>[12, 84, leftW, srcH]); track('db_src');
  ui.button('db_over', title: 'Run / Step Over', frame: <int>[12, btnY, 130, 28], onClick: () => debugRun(0)); track('db_over');
  ui.button('db_into', title: 'Step Into', frame: <int>[150, btnY, 96, 28], onClick: () => debugRun(1)); track('db_into');
  ui.button('db_out', title: 'Step Out', frame: <int>[254, btnY, 96, 28], onClick: () => debugRun(2)); track('db_out');
  ui.button('db_resume', title: 'Resume', frame: <int>[358, btnY, 96, 28], onClick: () => debugRun(3)); track('db_resume');

  var stackH = ((btnY - 82) * 0.42).round();
  ui.label('db_sl', text: 'Call stack (top frame first)', frame: <int>[rightX, 60, rightW, 18]); track('db_sl');
  ui.list('db_stack', frame: <int>[rightX, 82, rightW, stackH],
      rowCount: () => dbgStackLines.length, cellAt: (r) => dbgStackLines[r], onSelect: (r) {}); track('db_stack');

  var evalY = 82 + stackH + 12;
  ui.label('db_el', text: 'Evaluate in frame:', frame: <int>[rightX, evalY, 130, 18]); track('db_el');
  ui.field('db_eval', text: 'n * n', frame: <int>[rightX + 132, evalY - 2, rightW - 132, 24]); track('db_eval');
  ui.label('db_evalout', text: '(result appears here)', frame: <int>[rightX, evalY + 28, rightW, 18]); track('db_evalout');

  var logLY = evalY + 56;
  var logTop = logLY + 22;
  ui.label('db_ll', text: 'Session transcript', frame: <int>[rightX, logLY, rightW, 18]); track('db_ll');
  ui.editor('db_log', frame: <int>[rightX, logTop, rightW, btnY - logTop - 8]); track('db_log');
  ui.label('db_status', text: 'click Run / Step Over to start a debug session',
      frame: <int>[rightX, btnY + 4, rightW, 18]); track('db_status');

  ui.set('db_src', {'text': wr(_dbgRenderSource())});
  ui.commit();
  ui.applySpans('db_src', lexDart(_dbgRenderSource()));
}

// Arm the debugger with the chosen step mode, spawn the target isolate, and poll
// the captured session, refreshing the stack / paused line / eval / transcript.
void debugRun(int stepKind) {
  if (activeTab != 6 || dbgRunning) return;
  dbgRunning = true;
  dbgStackLines = <String>[];
  dbgPausedLine = -1;
  var expr = ui.textOf('db_eval');
  if (expr == null || expr.trim().isEmpty) expr = 'n * n';
  var modeName = const ['Step Over', 'Step Into', 'Step Out', 'Resume'][stepKind];
  wsDebugArm(kDbgBreakLine, expr.trim(), stepKind);
  ui.set('db_status', {'text': 'running ($modeName) ...'});
  ui.set('db_evalout', {'text': '(result appears here)'});
  ui.set('db_stack', {'rows': 0});
  ui.commit();

  var rp = new ReceivePort();
  rp.listen((m) { wsDebugDone(); });

  Isolate
      .spawnUri(Platform.script.resolve('debug_target.dart'), <String>[], rp.sendPort)
      .catchError((e) {
        ui.set('db_status', {'text': 'spawn error: $e'});
        ui.commit();
        dbgRunning = false;
      });

  var ticks = 0;
  dbgPollTimer = new Timer.periodic(new Duration(milliseconds: 100), (t) {
    ticks++;
    var st = wsDebugPoll();
    var done = st[0] == true;
    // st: [done, log, curLine, stack, evalResult, hit]
    dbgPausedLine = (st[2] is int) ? st[2] : -1;
    var stackStr = st[3].toString();
    dbgStackLines = stackStr.isEmpty ? <String>[] : stackStr.split('\n')
        .where((s) => s.trim().isNotEmpty).toList();
    ui.set('db_stack', {'rows': dbgStackLines.length});
    ui.set('db_log', {'text': wr(st[1].toString())});
    if (st[5] == true) ui.set('db_evalout', {'text': 'eval "$expr"  =>  ${st[4]}'});
    ui.set('db_src', {'text': wr(_dbgRenderSource())});
    ui.commit();
    ui.applySpans('db_src', lexDart(_dbgRenderSource()));
    if (done || ticks > 60) {
      t.cancel();
      dbgRunning = false;
      ui.set('db_status', {'text': done ? 'session complete ($modeName)' : 'timed out'});
      ui.commit();
      rp.close();
    }
  });
}

// ── Debug tab (deferred to T4): a placeholder panel ───────────────────────────
void buildPlaceholder(int i) {
  ui.label('ph_lbl', text: '${tabNames[i]}', frame: <int>[12, 40, 400, 22]); track('ph_lbl');
  ui.label('ph_note',
      text: 'The Debug tab (a vm-service client / breakpoints / stepping) is deferred to T4 — after the game pane (T3), per the user\'s priority order.',
      frame: <int>[12, 72, 1040, 18]); track('ph_note');
  ui.label('ph_note2',
      text: 'The vm-service protocol is already portable; this pane will host the debugger UI in a later slice.',
      frame: <int>[12, 98, 1040, 18]); track('ph_note2');
}

// ── Game tab (D3D11 game pane): run a gp game in its OWN isolate ──────────────
// The plug-in-app-off-the-UI-isolate model: the game runs in a spawned isolate that
// flushes ['draw', cmds] frames over a port; we gpOpen on the first `gpopen` command,
// then gpApply each frame and pull-pace the next. Mirrors test/game_live.dart.
final gpGames = const ['coindash', '13_invaders', '13_invaders_hlsl', '15_brickout', '12_copper', 'tiletest', 'rgbatest', 'fonttest', 'keyecho', 'abc'];
String gameSel = 'coindash';
const int gpW = 424, gpH = 240;              // logical game size (the engine letterboxes)
ReceivePort gameRp;
SendPort gameCtl;
Isolate gameIso;
bool gameOpened = false, gameDone = false;
int gameFrames = 0;

// Poll the live keyboard (GetAsyncKeyState -> [downMacCodes, mods], an untyped
// list) and ship it as this frame's gamestate, so g.key(...) works in the game.
void gameTick() { if (gameCtl != null && !gameDone && !gamePaused) gameCtl.send(keyState()); }
// The pull-pacer IS the freeze mechanism: no tick, no frame. It already stops
// when the Game tab is not showing; `gamePaused` adds an explicit user hold.
void gameSchedule() {
  if (!gameDone && !gamePaused && activeTab == 9) {
    new Timer(new Duration(milliseconds: 16), gameTick);
  }
}
// WINDARTARM: an explicit Pause hold, separate from the implicit tab-away
// freeze. Both work by withholding the tick rather than by tearing anything
// down, so the game resumes exactly where it stopped.
bool gamePaused = false;

// ── C5: run a Smalltalk game in the D3D11 game pane. The ST game runs in the
// language isolate (GamePane launch -> stepWithKeys: -> stGpTake), pushing the
// SAME ['port']/['draw']/gp* stream a Dart demo isolate does — so it renders
// through this one _gameFrame path + pull-tick.
bool _stGameActive = false;

void _gameFrame(List msg) {
  if (gameDone || msg.isEmpty) return;
  if (msg[0] == 'port') { gameCtl = msg[1]; gameTick(); return; }
  if (msg[0] == 'done') {
    gameDone = true;
    if (ui.ticketOf('gm_status') != null) ui.set('gm_status', {'text': 'done: ${msg.length > 1 ? msg[1] : ''}'});
    return;
  }
  if (msg[0] != 'draw') return;
  var cmds = msg[1];
  if (!gameOpened) {
    var first = (cmds is List && cmds.isNotEmpty && cmds[0] is List && cmds[0].isNotEmpty) ? cmds[0][0] : null;
    if (first == 'gpopen') {
      var o = cmds[0];
      // WINDARTARM: honour the MODE the driver sent. language.dart emits
      // ['gpopen', w, h, ww, wh, 1] for a `'direct': true` game; this dropped
      // o[5] and always passed 0, so the engine was never told a game wanted
      // the direct framebuffer.
      gpOpen(o[1], o[2], o[3], o[4], (o.length > 5 && o[5] is int) ? o[5] : 0);
      gameOpened = true;
      if (cmds.length > 1) _gpReport(gpApply(cmds.sublist(1)));
      gameFrames++;
      gameSchedule();
      return;
    }
    gpOpen(gpW, gpH, gpW, gpH, 0);
    gameOpened = true;
  }
  _gpReport(gpApply(cmds));   // apply + render_present + swapchain Present
  gameFrames++;
  gameSchedule();
}

// WINDARTARM: gpApply answers "" or the FIRST error of the batch, and both call
// sites used to discard it — so an op the engine rejected (an unknown verb, a
// shader that will not compile, a sprite out of sequence) failed completely
// silently and showed up only as something missing on screen. Report each
// DISTINCT message once: a bad op usually repeats every frame, so printing
// unconditionally would bury the log at 60 Hz.
Set<String> _gpSeenErrs = new Set<String>();
void _gpReport(e) {
  if (e == null) return;
  var s = e.toString();
  if (s.isEmpty || !_gpSeenErrs.add(s)) return;
  print('GPERR: $s');
}

void startStGame(String name) {
  stopGame();
  keyWatch(); keyCapture(true);
  gameSel = name; gameDone = false; gameOpened = false; gameFrames = 0;
  _stGameActive = true;
  if (ui.ticketOf('gm_status') != null) { ui.set('gm_status', {'text': 'running (Smalltalk): $name'}); ui.commit(); }
  ask('stgame', name).then((r) { if (r.toString().startsWith('ERR')) print('ST game $name: $r'); });
}

void stopGame() {
  gameDone = true;
  keyCapture(false);              // release the keyboard back to the workspace
  if (_stGameActive) { _stGameActive = false; if (_lang != null) ask('stgamestop', gameSel); }
  if (gameRp != null) { gameRp.close(); gameRp = null; }
  gameCtl = null;
  if (gameIso != null) { try { gameIso.kill(priority: Isolate.immediate); } catch (e) {} gameIso = null; }
  if (gameOpened) { gpClose(); gameOpened = false; }
}

void startGame(String name) {
  stopGame();
  keyWatch();
  keyCapture(true);               // the game owns the keyboard while it runs
  gameSel = name;
  gameDone = false; gameOpened = false; gameFrames = 0;
  var rp = new ReceivePort();
  gameRp = rp;
  rp.listen((msg) {
    if (rp != gameRp || msg is! List) return;     // stale/late frame from a prior run
    _gameFrame(msg);
  });
  Isolate.spawnUri(Platform.script.resolve('demos/$name.dart'), <String>['$gpW', '$gpH'], rp.sendPort)
      .then((iso) { gameIso = iso; })
      .catchError((e) { print('GAME: spawn error $name: $e'); });
}

// WINDARTARM: the Smalltalk games, appended to the Dart demo list so BOTH
// languages are pickable from one place. Filled from the language isolate's
// `stgames` (each entry [name, description, available]); empty until the ST
// world has imported, and refreshed on every Game-tab build.
List<String> stGames = <String>[];
void refreshStGames() {
  if (_lang == null) return;
  ask('stgames', '').then((r) {
    var names = <String>[];
    if (r is List) {
      for (var g in r) {
        if (g is List && g.isNotEmpty) names.add(g[0].toString());
      }
    }
    if (names.length == stGames.length) return;   // no change -> no rebuild
    stGames = names;
    if (activeTab == 9 && ui.ticketOf('gm_list') != null) {
      // The list is created with {'rows': n} and pulls cellAt() per row, so
      // re-stating the count is what makes the host re-read it.
      ui.set('gm_list', {'rows': _gameRowCount});
      ui.commit();
    }
  });
}
// One flat list: Dart demos first, then ST games. Row index maps back by range.
int get _gameRowCount => gpGames.length + stGames.length;
String _gameRowLabel(int r) =>
    (r < gpGames.length) ? gpGames[r] : '▸ ' + stGames[r - gpGames.length];
void _gameRowSelect(int r) {
  if (r < 0 || r >= _gameRowCount) return;
  if (r < gpGames.length) {
    startGame(gpGames[r]);                       // Dart demo -> its own isolate
  } else {
    startStGame(stGames[r - gpGames.length]);    // Smalltalk -> language isolate
  }
}

void buildGame() {
  var W = paneW, H = paneH;
  ui.label('gm_lbl', text: 'Game   -   pick a game (▸ = Smalltalk); it runs in its OWN isolate, flushing frames to the D3D11 pane',
      frame: <int>[12, 36, W - 24, 18]); track('gm_lbl');
  ui.list('gm_list', frame: <int>[12, 60, 180, H - 126],
      rowCount: () => _gameRowCount, cellAt: (r) => _gameRowLabel(r),
      onSelect: _gameRowSelect); track('gm_list');
  // Pause holds the pull-pacer (the game keeps its state); Stop tears the
  // isolate down and closes the pane.
  ui.button('gm_pause', title: gamePaused ? 'Resume' : 'Pause',
      frame: <double>[12.0, (H - 92).toDouble(), 86.0, 26.0],
      onClick: () {
        gamePaused = !gamePaused;
        ui.set('gm_pause', {'title': gamePaused ? 'Resume' : 'Pause'});
        ui.set('gm_status', {'text': gameStatusText()});
        ui.commit();
        if (!gamePaused) gameSchedule();          // resume where it left off
      }); track('gm_pause');
  ui.button('gm_stop', title: 'Stop',
      frame: <double>[104.0, (H - 92).toDouble(), 86.0, 26.0],
      onClick: () {
        stopGame();
        gamePaused = false;
        ui.set('gm_pause', {'title': 'Pause'});
        ui.set('gm_status', {'text': gameStatusText()});
        ui.commit();
      }); track('gm_stop');
  ui.label('gm_status', text: gameStatusText(), frame: <int>[12, H - 30, 180, 18]); track('gm_status');
  var gx = 204;
  ui.game('gp', frame: <int>[gx, 60, W - gx - 12, H - 72]); track('gp');
  ui.commit();
  refreshStGames();
  // WINDARTARM: only re-launch a DART game on a tab rebuild. `gameSel` also
  // holds the name when a SMALLTALK game is running (startStGame sets it), and
  // handing that to the Dart spawner threw
  //   IsolateSpawnException: Could not load ".../demos/<StName>.dart"
  // on every single ST game launch — the file does not exist, because an ST
  // game lives in the image, not in demos/. Worse, startGame() opens with
  // stopGame(), so this also tore down the ST game it had just started.
  // An ST game keeps streaming frames from the language isolate across a tab
  // rebuild, so there is nothing to re-launch here.
  // Returning to the tab: if a game is still live (frozen by the tab-away
  // pause, not killed), just re-arm the pacer. Only launch afresh when there
  // is nothing running — and never hand a Smalltalk name to the Dart spawner.
  if (!gameDone && (gameCtl != null || _stGameActive)) {
    gameSchedule();
  } else if (!_stGameActive && gameSel.isNotEmpty) {
    startGame(gameSel);
  }
}

// "running: X" / "paused: X" / "stopped" — one place, so the label, the Pause
// button and the Stop button cannot disagree.
String gameStatusText() {
  if (gameDone || (gameCtl == null && !_stGameActive)) return 'stopped';
  var kind = _stGameActive ? ' (Smalltalk)' : '';
  return (gamePaused ? 'paused: ' : 'running: ') + gameSel + kind;
}

// ── Inspect tab (T10): the Smalltalk object inspector ─────────────────────────
// Evaluate an expression in the language isolate, which RETAINS the result and
// reflects it into a self + instance-variables view. Selecting a slot shows its
// printString; Dive re-inspects that slot's value (drills into the live object
// graph), Back pops. ST objects never cross the wire — all reflection is
// server-side (language.dart inspect/inspectivar/inspectback), and only the flat
// [class, printString, [[name,value],...]] view comes back.
String inspClass = '', inspPrint = '';
List<List<String>> inspIvars = <List<String>>[];   // [ivarName, valuePrintString]
int inspSel = 0;                                    // 0 = self, 1..n = ivar row
String inspExprText = '3 / 4';

void _showInspSlot(int s) {
  inspSel = s;
  var text;
  if (s == 0) {
    text = 'self  :  ' + inspClass + '\n\n' + inspPrint;
  } else if (s - 1 < inspIvars.length) {
    text = inspIvars[s - 1][0] + '  =\n\n' + inspIvars[s - 1][1];
  } else {
    text = '';
  }
  ui.set('insp_detail', {'text': wr(text)});
  ui.commit();
}

void _paintInspect() {
  ui.set('insp_hdr', {'text': inspClass.isEmpty
      ? '(nothing inspected — type an expression and click Inspect)'
      : inspClass + '        ' + inspPrint});
  ui.set('insp_slots', {'rows': inspIvars.length + 1});
  _showInspSlot(inspSel <= inspIvars.length ? inspSel : 0);
  ui.commit();
}

void _renderInspect(r) {
  if (r is List && r.length >= 3) {
    inspClass = r[0].toString();
    inspPrint = r[1].toString();
    inspIvars = <List<String>>[];
    if (r[2] is List) {
      for (var e in r[2]) {
        if (e is List && e.length >= 2) {
          inspIvars.add(<String>[e[0].toString(), e[1].toString()]);
        }
      }
    }
    inspSel = 0;
    _paintInspect();
  } else {
    inspClass = ''; inspPrint = ''; inspIvars = <List<String>>[];
    ui.set('insp_hdr', {'text': 'Inspect error: ' + r.toString()});
    ui.set('insp_slots', {'rows': 0});
    ui.set('insp_detail', {'text': wr(r.toString())});
    ui.commit();
  }
}

Future doInspect(String expr) {
  inspExprText = expr;
  return ask('inspect', expr).then(_renderInspect);
}
Future inspectDive() {
  if (inspSel < 1) return new Future.value();
  return ask('inspectivar', inspSel.toString()).then(_renderInspect);
}
Future inspectBack() => ask('inspectback', '').then(_renderInspect);

void buildInspect() {
  var W = paneW, H = paneH;
  ui.label('insp_lbl',
      text: 'Inspector   -   evaluate an expression, then Dive into its instance variables (Smalltalk or Dart)',
      frame: <int>[12, 36, W - 24, 18]); track('insp_lbl');
  ui.field('insp_expr', text: inspExprText, frame: <int>[12, 60, W - 320, 24]); track('insp_expr');
  ui.button('insp_go', title: 'Inspect', frame: <int>[W - 300, 58, 92, 28],
      onClick: () => doInspect(ui.textOf('insp_expr'))); track('insp_go');
  ui.button('insp_dive', title: 'Dive', frame: <int>[W - 204, 58, 84, 28], onClick: inspectDive); track('insp_dive');
  ui.button('insp_back', title: 'Back', frame: <int>[W - 116, 58, 84, 28], onClick: inspectBack); track('insp_back');
  ui.label('insp_hdr', text: '(nothing inspected)', frame: <int>[12, 90, W - 24, 18]); track('insp_hdr');
  var top = 132, listW = (W - 36) ~/ 2, bodyH = H - top - 16;
  ui.label('insp_sl', text: 'self + instance variables  (name : value)', frame: <int>[12, top - 20, listW, 18]); track('insp_sl');
  ui.list('insp_slots', frame: <int>[12, top, listW, bodyH],
      rowCount: () => inspIvars.length + 1,
      cellAt: (r) => r == 0
          ? 'self  :  ' + inspClass
          : (r - 1 < inspIvars.length ? inspIvars[r - 1][0] + '  :  ' + inspIvars[r - 1][1] : ''),
      onSelect: (r) => _showInspSlot(r)); track('insp_slots');
  ui.label('insp_dl', text: 'selected slot', frame: <int>[12 + listW + 12, top - 20, W - 24 - listW - 12, 18]); track('insp_dl');
  ui.editor('insp_detail', frame: <int>[12 + listW + 12, top, W - 24 - listW - 12, bodyH]); track('insp_detail');
  ui.commit();
  if (inspClass.isEmpty) doInspect(inspExprText); else _paintInspect();
}

// ── ST Debug tab (T11): the Smalltalk post-mortem debugger ────────────────────
// Run an expression in the language isolate; on failure it answers the call
// STACK. ST compiles to Dart IL, so the frames ARE the ST methods (DbgDemo>>inner
// with an st:mst source location) — we keep those and drop the Dart plumbing.
// A full live stepper (breakpoints, resume, frame locals) needs the VM-service
// client pointed at the language isolate — a separate native slice; this shows
// where an error/`halt` happened, and hands the receiver to the Inspector.
List<List<String>> sdbFrames = <List<String>>[];   // [displayName, rawFrame]
String sdbError = '', sdbResult = '';
int sdbSel = -1;
String sdbExprText = '(Array new: 3) at: 10';

// Keep only ST frames (located in st:mst source), reformatted ClassName>>selector.
List<List<String>> _stFramePairs(List raw) {
  var out = <List<String>>[];
  var re = new RegExp(r'#\d+\s+(.+?)\s+\(st:mst/');
  for (var f in raw) {
    var s = f.toString();
    if (!s.contains('st:mst/')) continue;          // drop dart:* / wire plumbing
    var m = re.firstMatch(s);
    var name = m == null ? s : m.group(1);
    if (new RegExp(r'^STInsp\d+ class\.doIt$').hasMatch(name)) {
      name = '<Do It>';
    } else if (name.contains(' class.')) {
      name = name.replaceFirst(' class.', ' class>>');
    } else {
      name = name.replaceFirst('.', '>>');
    }
    out.add(<String>[name, s]);
  }
  return out;
}

void _showStFrame(int i) {
  sdbSel = i;
  var text;
  if (i < 0 || i >= sdbFrames.length) {
    text = sdbError.isEmpty ? (sdbResult.isEmpty ? '' : 'Result:\n\n' + sdbResult) : sdbError;
  } else {
    text = 'Frame:  ' + sdbFrames[i][0] + '\n\n' + sdbFrames[i][1] + '\n\n— error —\n' + sdbError;
  }
  ui.set('sdb_detail', {'text': wr(text)});
  ui.commit();
}

void _renderStDebug(r) {
  if (r is! List || r.isEmpty) {
    sdbError = 'bad reply: ' + r.toString(); sdbResult = ''; sdbFrames = <List<String>>[];
    ui.set('sdb_status', {'text': sdbError});
    ui.set('sdb_stack', {'rows': 0});
    ui.set('sdb_detail', {'text': wr(sdbError)});
    ui.commit();
    return;
  }
  if (r[0] == 'ok') {
    sdbResult = r.length > 1 ? r[1].toString() : '';
    sdbError = ''; sdbFrames = <List<String>>[];
    ui.set('sdb_status', {'text': 'ran clean   =>   ' + sdbResult + '     (Inspect result to explore it)'});
    ui.set('sdb_stack', {'rows': 0});
  } else {
    sdbError = r.length > 1 ? r[1].toString() : 'error';
    sdbFrames = _stFramePairs((r.length > 2 && r[2] is List) ? r[2] : <dynamic>[]);
    sdbResult = '';
    var head = sdbError.split('\n')[0];
    ui.set('sdb_status', {'text': 'RAISED:   ' + head + '     (' + sdbFrames.length.toString() + ' Smalltalk frames)'});
    ui.set('sdb_stack', {'rows': sdbFrames.length});
  }
  sdbSel = -1;
  _showStFrame(-1);
  ui.commit();
}

Future debugStRun(String expr) {
  sdbExprText = expr;
  return ask('stdebug', expr).then(_renderStDebug);
}

void buildStDebug() {
  var W = paneW, H = paneH;
  ui.label('sdb_lbl',
      text: 'Smalltalk debugger   -   run an expression; on error see the call stack (post-mortem). Inspect result opens it in the Inspector.',
      frame: <int>[12, 36, W - 24, 18]); track('sdb_lbl');
  ui.field('sdb_expr', text: sdbExprText, frame: <int>[12, 60, W - 320, 24]); track('sdb_expr');
  ui.button('sdb_go', title: 'Run', frame: <int>[W - 300, 58, 92, 28],
      onClick: () => debugStRun(ui.textOf('sdb_expr'))); track('sdb_go');
  ui.button('sdb_insp', title: 'Inspect result', frame: <int>[W - 204, 58, 172, 28],
      onClick: () { switchTab(10); doInspect(ui.textOf('sdb_expr')); }); track('sdb_insp');
  ui.label('sdb_status', text: 'run an expression to debug it', frame: <int>[12, 90, W - 24, 18]); track('sdb_status');
  var top = 132, listW = (W - 36) ~/ 2, bodyH = H - top - 16;
  ui.label('sdb_sl', text: 'call stack  (top frame first — where it raised)', frame: <int>[12, top - 20, listW, 18]); track('sdb_sl');
  ui.list('sdb_stack', frame: <int>[12, top, listW, bodyH],
      rowCount: () => sdbFrames.length,
      cellAt: (r) => r >= 0 && r < sdbFrames.length ? sdbFrames[r][0] : '',
      onSelect: (r) => _showStFrame(r)); track('sdb_stack');
  ui.label('sdb_dl', text: 'detail', frame: <int>[12 + listW + 12, top - 20, W - 24 - listW - 12, 18]); track('sdb_dl');
  ui.editor('sdb_detail', frame: <int>[12 + listW + 12, top, W - 24 - listW - 12, bodyH]); track('sdb_detail');
  ui.commit();
  _showStFrame(sdbSel);
}

// ── Catalog tab (T12): the rolling app/game/demo gallery ──────────────────────
// Enumerates every runnable class the image holds — apps (a `build:` method),
// games, demos — and launches one on click. "Load .mst" imports a file into the
// language isolate (stimport handles a single file), so dropping a new app/game
// .mst here makes it APPEAR in the gallery — this is the "rolling support".
List<String> catApps = <String>[];                       // apps -> plain class names
List<List<String>> catGames = <List<String>>[], catDemos = <List<String>>[];  // [name, description]
String catPathText = '$_stWorldDir/81_appui.mst';

List<String> _toStrList(x) => (x is List) ? x.map((e) => e.toString()).toList() : <String>[];
// games/demos answer [name, description, file] tuples; keep name (launch key) + description.
List<List<String>> _toPairList(x) {
  var out = <List<String>>[];
  if (x is List) {
    for (var e in x) {
      if (e is List && e.isNotEmpty) out.add(<String>[e[0].toString(), e.length > 1 ? e[1].toString() : '']);
      else out.add(<String>[e.toString(), '']);
    }
  }
  return out;
}

Future _catRefresh() async {
  if (_lang == null) return;
  catApps = _toStrList(await ask('apps', ''));
  catGames = _toPairList(await ask('stgames', ''));
  catDemos = _toPairList(await ask('stdemos', ''));
  ui.set('cat_apps', {'rows': catApps.length});
  ui.set('cat_games', {'rows': catGames.length});
  ui.set('cat_demos', {'rows': catDemos.length});
  ui.set('cat_al', {'text': 'Apps (${catApps.length})'});
  ui.set('cat_gl', {'text': 'Games (${catGames.length})'});
  ui.set('cat_dl', {'text': 'Demos (${catDemos.length})'});
  ui.set('cat_status', {'text': 'catalog: ${catApps.length} apps, ${catGames.length} games, ${catDemos.length} demos   -   click an app or game to run it'});
  ui.commit();
}

Future _catLoad(String path) async {
  if (_lang == null || path.trim().isEmpty) return;
  var r = await ask('stimport', path.trim());
  var before = catApps.length + catGames.length;
  // A freshly imported .mst adds classes — refresh the ST class set too so the
  // browser and Find see them, then re-enumerate the gallery.
  var names = _toStrList(await ask('classes', ''));
  _stClasses = new Set<String>.from(names);
  names.sort();
  classesInLib['smalltalk'] = names;
  for (var n in names) libOfClass[n] = 'smalltalk';
  await _catRefresh();
  var added = (catApps.length + catGames.length) - before;
  ui.set('cat_status', {'text': 'loaded ' + path.trim() + '  ->  ' + r.toString() + '   (+' + added.toString() + ' runnable)'});
  ui.commit();
}

void _catRunApp(int r) {
  if (r < 0 || r >= catApps.length) return;
  _appName = catApps[r];
  switchTab(5);                                   // App pane
  ui.set('app_status', {'text': 'running: $_appName'});
  ui.commit();
  if (_lang != null) ask('apprun', [_appName, paneW.toDouble(), paneH.toDouble()]);
}

void _catRunGame(int r) {
  if (r < 0 || r >= catGames.length) return;
  switchTab(9);                                   // Game pane
  startStGame(catGames[r][0]);
}

void _catRunDemo(int r) {
  if (r < 0 || r >= catDemos.length || _lang == null) return;
  var name = catDemos[r][0];
  ask('stdemo', name).then((res) {
    ui.set('cat_status', {'text': 'demo ' + name + '  ->  ' + res.toString().split('\n')[0]});
    ui.commit();
  });
}

void buildCatalog() {
  var W = paneW, H = paneH;
  ui.label('cat_lbl', text: 'Catalog   -   click an app or game to run it. Load an .mst to add new ones (rolling support).', frame: <int>[12, 36, W - 24, 18]); track('cat_lbl');
  ui.label('cat_pl', text: 'Load .mst:', frame: <int>[12, 62, 72, 20]); track('cat_pl');
  ui.field('cat_path', text: catPathText, frame: <int>[86, 60, W - 320, 24]); track('cat_path');
  ui.button('cat_load', title: 'Load', frame: <int>[W - 224, 58, 92, 28], onClick: () { _catLoad(ui.textOf('cat_path')); }); track('cat_load');
  ui.button('cat_refresh', title: 'Refresh', frame: <int>[W - 124, 58, 92, 28], onClick: () { _catRefresh(); }); track('cat_refresh');
  ui.label('cat_status', text: '(loading catalog...)', frame: <int>[12, 92, W - 24, 18]); track('cat_status');
  var top = 138, colW = (W - 48) ~/ 3, bodyH = H - top - 16;
  var x0 = 12, x1 = 12 + colW + 12, x2 = 12 + 2 * (colW + 12);
  ui.label('cat_al', text: 'Apps', frame: <int>[x0, top - 20, colW, 18]); track('cat_al');
  ui.list('cat_apps', frame: <int>[x0, top, colW, bodyH],
      rowCount: () => catApps.length, cellAt: (r) => r < catApps.length ? catApps[r] : '', onSelect: _catRunApp); track('cat_apps');
  ui.label('cat_gl', text: 'Games', frame: <int>[x1, top - 20, colW, 18]); track('cat_gl');
  ui.list('cat_games', frame: <int>[x1, top, colW, bodyH],
      rowCount: () => catGames.length, cellAt: (r) => r < catGames.length ? catGames[r][0] + '   —   ' + catGames[r][1] : '', onSelect: _catRunGame); track('cat_games');
  ui.label('cat_dl', text: 'Demos', frame: <int>[x2, top - 20, colW, 18]); track('cat_dl');
  ui.list('cat_demos', frame: <int>[x2, top, colW, bodyH],
      rowCount: () => catDemos.length, cellAt: (r) => r < catDemos.length ? catDemos[r][0] + '   —   ' + catDemos[r][1] : '', onSelect: _catRunDemo); track('cat_demos');
  ui.commit();
  _catRefresh();
}

void buildTab(int i) {
  // WINDARTARM: leaving the Game tab still STOPS the game, deliberately.
  //
  // Freezing instead (just letting gameSchedule() decline to arm the next tick,
  // which it already does when activeTab != 9) looks correct and crashes: the
  // tab switch runs clearContent(), which destroys the 'gp' surface window,
  // while the engine keeps its swapchain bound to that HWND — the next Present
  // faults and takes dartui down with no Dart-level error. Verified by trying
  // it: MandelZoom, leave tab, return -> process gone.
  //
  // A real freeze therefore needs pane lifecycle work (close the surface on
  // leave, reopen and re-upload on return) rather than a scheduling tweak.
  // Until then the in-tab Pause button is the freeze: it holds the pacer
  // without touching any window. See port-arm64/AS6_NOTES.md.
  if (activeTab == 9 && i != 9) { stopGame(); gamePaused = false; }
  activeTab = i;
  clearContent();
  switch (i) {
    case 0: buildWorkspace(); break;
    case 1: buildBrowser(); break;
    case 2: buildEditor(); break;
    case 3: buildFind(); break;
    case 4: buildDocs(); break;
    case 5: buildApp(); break;
    case 6: buildDebug(); break;
    case 7: buildVM(); break;
    case 8: buildHelp(); break;
    case 9: buildGame(); break;
    case 10: buildInspect(); break;
    case 11: buildStDebug(); break;
    case 12: buildCatalog(); break;
    default: buildPlaceholder(i); break;
  }
  ui.commit();
  wsSetStatus('${tabNames[i]}     |     WINDART   -   image: $imgPath');
}

void switchTab(int i) {          // programmatic (self-test): set the strip + rebuild
  ui.set('tabs', {'tab': i});
  buildTab(i);
}

// Coalesce a burst of WM_SIZE events (a continuous border drag fires many per
// second) into ONE relayout on the trailing edge — a full tab teardown/rebuild
// per event flickers the RichEdit controls. paneW/paneH track the latest size
// immediately so a mid-drag tab switch still lays out at the current bounds.
Timer _resizeTimer = null;
int _resizeW = 0, _resizeH = 0;
void onResizeCoalesced(int w, int h) {
  if (w <= 0 || h <= 0) return;
  _resizeW = w; _resizeH = h;
  paneW = w; paneH = h;
  if (_resizeTimer != null) _resizeTimer.cancel();
  _resizeTimer = new Timer(new Duration(milliseconds: 60), () {
    _resizeTimer = null;
    relayout(_resizeW, _resizeH);
  });
}

// Reflow for a new pane (container) size (kind-7 resize). Re-place the tab strip
// across the new width, then rebuild the active tab so its size-parameterized
// layout fills the new bounds. buildTab commits; the strip 'place' rides along.
void relayout(int w, int h) {
  if (w <= 0 || h <= 0) return;
  paneW = w; paneH = h;
  ui.place('tabs', <int>[0, 0, w, 26]);
  buildTab(activeTab);
  print('RESIZE: pane ${w}x$h -> tab $activeTab relaid out');
}

void snap(String name) {
  var e = ui.snapshot(outPng(name));
  print('SNAP: $name ${e.isEmpty ? "OK" : "ERR:$e"}');
}

// ── menu / toolbar commands (polled from the host queue) ──────────────────────
// The host's menu bar + icon toolbar push Dart-routed command ids; we poll them
// (wsMenuPoll) and map ids -> actions. Ids MUST match win_host.h (WinHostCommand).
void menuDoIt() {
  if (activeTab != 0) switchTab(0);
  var code = ui.textOf('ws_editor');
  if (code == null) return;
  code = code.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
  if (code.isEmpty) return;
  var result = wsEval(code);
  wsLog.writeln('$code   =>   $result');
  ui.set('ws_output', {'text': wr(wsLog.toString())});
  ui.commit();
  print('MENU-DOIT: $code => $result');
}

void dispatchMenu(int id) {
  if (id >= 200 && id <= 208) { switchTab(id - 200); print('MENU: tab ${id - 200}'); return; }
  switch (id) {
    case 140: case 141: menuDoIt(); break;                 // Do It / Print It
    case 148:                                              // Refresh
      buildTab(activeTab); if (activeTab == 7) refreshVM(); break;
    case 130:                                              // New Class
      switchTab(2);
      currentEditClass = 'NewClass';
      ui.set('ed_source', {'text': wr('class NewClass {\n  \n}')});
      ui.set('ed_status', {'text': 'new class (edit + Accept to create)'});
      ui.commit();
      break;
    case 131: buildEditorClassList(); switchTab(2); break; // Open (refresh class list)
    case 132: if (activeTab != 2) switchTab(2); accept(); break;   // Save
    case 145: browseHome(); break;                         // Home -> Browser, top class
    case 146: browseBack(); break;                         // Back (browser history)
    case 147: browseForward(); break;                      // Forward (browser history)
    case 149: switchTab(3); break;                         // Find
    case 150: switchTab(1); break;                         // Browse -> Browser
    default: break;
  }
  print('MENU: dispatched cmd $id');
}

void pollMenu() {
  var id = wsMenuPoll();
  while (id >= 0) { dispatchMenu(id); id = wsMenuPoll(); }
}

// ── main ─────────────────────────────────────────────────────────────────────
main(List<String> args) {
  var selftest = args.contains('selftest');
  var bake = args.contains('bake');   // W1: write the on-disk snapshot into the image
  spawnLanguage();   // C1: start the bilingual language isolate (Do It routes here)
  registerDartuiExt();   // C-harness: ext.dartui.send for TCL GUI control + snapshots

  // Browser data: the VM's class table, grouped by library (the Browser's
  // categories). classMirrors/classNames stay flat for Find/Docs/nav.
  for (var lib in currentMirrorSystem().libraries.values) {
    var lname;
    try { lname = lib.uri.toString(); }
    catch (e) { lname = MirrorSystem.getName(lib.simpleName); }
    var inLib = <String>[];
    lib.declarations.forEach((sym, decl) {
      if (decl is ClassMirror) {
        var name = MirrorSystem.getName(decl.simpleName);
        if (name.isNotEmpty && !name.startsWith('_')) {
          classMirrors[name] = decl;
          inLib.add(name);
          libOfClass.putIfAbsent(name, () => lname);
        }
      }
    });
    if (inLib.isNotEmpty) {
      inLib.sort();
      classesInLib[lname] = inLib;
      libraryNames.add(lname);
    }
  }
  libraryNames.sort();
  classNames = classMirrors.keys.toList()..sort();

  // The workspace image.
  var home = Platform.environment['USERPROFILE'];
  var dir = new Directory(home + '\\.windart');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  imgPath = (dir.path + '\\workspace.sqlite').replaceAll('\\', '/');
  var db = openImage(); db.close();   // ensure the image + table exist

  // Stage 1: a live user-class instance to morph on Accept (single isolate).
  liveCounter = new Counter()..bump()..bump()..bump();   // n = 3
  print('STAGE1: liveCounter created (Counter.n=${liveCounter.n})');

  ui = new Ui.pane(1084, 740);
  // Size the initial layout to the real pane (Win_surfaceSize reads the container's
  // client rect); fall back to the defaults if it is not ready.
  var w0 = ui.width, h0 = ui.height;
  if (w0 > 0) paneW = w0;
  if (h0 > 0) paneH = h0;
  ui.title('WINDART Workspace   -   a live Windows Dart IDE');
  ui.tabs('tabs', items: tabNames, frame: <int>[0, 0, paneW, 26], onSelect: (i) => buildTab(i));
  ui.onResize(onResizeCoalesced); // reflow on window resize (kind 7), debounced
  persistentWidgets = ui.widgetIds.toSet();  // the tab strip (+ any chrome) survives switches
  buildTab(0);
  ui.commit();
  uiReady();

  // Headless one-shot commands (bake / export / import): the image work runs after
  // the UI is up but BEFORE the periodic timers, so the fast quit does not race the
  // 150 ms pollMenu tick during the first wake (that race left the isolate teardown
  // exiting -1). One Timer dispatches whichever command was asked for, then quits.
  var oneShot = null;
  if (bake) {
    // W1: bake the on-disk snapshot .bin into the image; the NEXT boot loads it
    // from the DB blob (win_host fallback chain).
    oneShot = () => print('BAKE: ' + wsBakeSnapshot());
  } else if (args.contains('rollback-snapshot')) {
    // W3: promote the @prev snapshot back to current (roll back the last bake).
    oneShot = () => print('ROLLBACK: ' + wsRollbackSnapshot());
  } else if (args.contains('recreate-snapshot')) {
    // W5: regenerate the boot snapshot via gen_snapshot, then versioned-bake it.
    oneShot = recreateSnapshot;
  } else {
    // W2 git bridge: export <dir> projects the image to loose files; import <dir>
    // builds <dir>/world.sqlite from them (never the live image).
    var wExport = args.indexOf('export');
    var wImport = args.indexOf('import');
    if (wExport >= 0 && wExport + 1 < args.length) {
      var dir = args[wExport + 1];
      oneShot = () => print('EXPORT: ' + wsExportWorld(dir));
    } else if (wImport >= 0 && wImport + 1 < args.length) {
      var dir = args[wImport + 1];
      oneShot = () => print('IMPORT: ' + wsImportWorld(dir, dir + '/world.sqlite'));
    }
  }
  if (oneShot != null) {
    // Exit via dart:io exit(0) rather than hostQuit()/WM_CLOSE: the GUI teardown on
    // the fast one-shot path reports process exit -1, which would make a release
    // script think import-world failed. exit(0) is a clean, deterministic 0.
    new Timer(new Duration(milliseconds: 300), () { oneShot(); exit(0); });
    return;   // a one-shot command starts no periodic timers
  }

  new Timer.periodic(new Duration(seconds: 1), (_) => refreshVM());
  new Timer.periodic(new Duration(milliseconds: 150), (_) => pollMenu());   // menu/toolbar
  new Timer.periodic(new Duration(seconds: 1), (_) => pushToolbarMetric());  // toolbar graph
  pushToolbarMetric();

  if (selftest) {
    // Pick a class with rich members for the Browser snapshot.
    var rich = classNames.isNotEmpty ? classNames[0] : '';
    var best = -1;
    classMirrors.forEach((name, cm) {
      var c = 0;
      cm.declarations.forEach((s, d) { var nm = MirrorSystem.getName(s); if (nm.isNotEmpty && !nm.startsWith('_')) c++; });
      if (c > best) { best = c; rich = name; }
    });
    var richIdx = classNames.indexOf(rich);
    var docIdx = richIdx;
    for (var name in const ['Duration','DateTime','Uri','StringBuffer','List','Object']) {
      var i = classNames.indexOf(name); if (i >= 0) { docIdx = i; break; }
    }

    var t = 400;
    new Timer(new Duration(milliseconds: t), () { switchTab(1); selectClass(richIdx); snap('tab_browser'); }); t += 450;
    // Item 4: categorized drill-down — library -> class -> vars/methods -> source.
    new Timer(new Duration(milliseconds: t), () {
      switchTab(1);
      var li = libraryNames.indexOf('dart:io');
      if (li >= 0) selectLibrary(li);
      print('CATBROWSE: dart:io -> ${libClasses.length} classes');
    }); t += 450;
    new Timer(new Duration(milliseconds: t), () {
      var ci = libClasses.indexOf('File');
      if (ci < 0 && libClasses.isNotEmpty) ci = 0;
      if (ci >= 0) selectLibClass(ci);
    }); t += 450;
    new Timer(new Duration(milliseconds: t), () { snap('browser_categorized'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { if (brMethods.isNotEmpty) selectBrMethod(0); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { snap('browser_member'); }); t += 450;
    // P3: instance/class side toggle — Duration has a rich class side (static
    // consts + ctor) and a full instance side (accessors/operators/methods).
    new Timer(new Duration(milliseconds: t), () { browseToClass('Duration'); snap('browser_instanceside'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { setBrowserSide(1); snap('browser_classside'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { setBrowserSide(0); }); t += 300;
    // P4: real on-disk SDK source — the Source pane shows actual bodies, not
    // just mirror signatures. Capture the class source and one method body.
    new Timer(new Duration(milliseconds: t), () { browseToClass('Duration'); snap('browser_realsource'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () {
      var mi = 0;
      for (var i = 0; i < brMethods.length; i++) { if (brMethods[i].contains('abs(')) { mi = i; break; } }
      selectBrMethod(mi); snap('browser_realmethod');
    }); t += 450;
    // Item 5: draggable splitter — capture the divider at rest, then after a drag.
    new Timer(new Duration(milliseconds: t), () { switchTab(1); selectClass(richIdx); }); t += 500;
    new Timer(new Duration(milliseconds: t), () { snap('splitter_before'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () {
      var tk = ui.ticketOf('br_split');
      if (tk != null) wsDragWidget(tk, 120, 0);    // drag the divider 120px right
      print('SPLIT: dragged br_split ticket=$tk');
    }); t += 450;
    new Timer(new Duration(milliseconds: t), () { snap('splitter_after'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { switchTab(0); doIt(); snap('tab_workspace'); }); t += 450;
    // C1: bilingual Do It — Smalltalk AND Dart through the same workspace wire.
    new Timer(new Duration(milliseconds: t), () {
      ask('doit', '25 sqrt').then((r) => print('ST-DOIT: 25 sqrt => $r'));
      ask('doit', '#(1 2 3) size').then((r) => print('ST-DOIT: #(1 2 3) size => $r'));
      ask('doit', 'st> 6 * 7').then((r) => print('ST-DOIT: st> 6*7 => $r'));
      ask('doit', '(2 + 3) * 7').then((r) => print('ST-DOIT: (2+3)*7 => $r'));
    }); t += 600;
    new Timer(new Duration(milliseconds: t), () { switchTab(2); snap('tab_editor'); }); t += 450;
    // Item 3: a VM class in the Editor shows the full declaration incl. real
    // method signatures (return + parameter types), not just member names.
    new Timer(new Duration(milliseconds: t), () {
      switchTab(2);
      var i = editorClassList.indexOf('Duration');
      if (i >= 0) ui.set('ed_class', {'index': i});
      loadEditorClass('Duration');
    }); t += 500;
    new Timer(new Duration(milliseconds: t), () { snap('editor_vmclass'); }); t += 450;
    // Stage 1: LIVE MORPH in the IDE. Counter v1 (n; bump+1) -> v2 (add `int step
    // = 7`; bump += step). Accept rewrites user_lib.dart from the image + reloads;
    // the live liveCounter (n=3) KEEPS n=3 and GAINS step=7 (state kept, field added).
    new Timer(new Duration(milliseconds: t), () {
      switchTab(2);
      var ci = editorClassList.indexOf('Counter');
      if (ci >= 0) ui.set('ed_class', {'index': ci});
      loadEditorClass('Counter');
      ui.set('ed_status', {'text': 'before Accept -> ' + liveState()});
      ui.commit();
    }); t += 500;
    new Timer(new Duration(milliseconds: t), () { snap('editor_counter_v1'); }); t += 400;
    new Timer(new Duration(milliseconds: t), () {
      var v2 = 'class Counter {\n  int n = 0;\n  int inc() => 7;\n  Counter bump() { n = n + inc(); return this; }\n}';
      ui.set('ed_source', {'text': wr(v2)});
      ui.commit();
      currentEditClass = 'Counter';
      accept();   // -> image + user_lib.dart -> reload -> morph; accept reads liveState after 350ms
    }); t += 950;
    new Timer(new Duration(milliseconds: t), () { snap('editor_morph'); }); t += 450;
    // W3 (versioning): a second Accept (step=11) leaves the step=7 version on the
    // undo stack; Revert pops it and morphs the live instance back to step=7.
    new Timer(new Duration(milliseconds: t), () {
      var v3 = 'class Counter {\n  int n = 0;\n  int inc() => 11;\n  Counter bump() { n = n + inc(); return this; }\n}';
      ui.set('ed_source', {'text': wr(v3)});
      ui.commit();
      currentEditClass = 'Counter';
      accept();
    }); t += 950;
    new Timer(new Duration(milliseconds: t), () { currentEditClass = 'Counter'; revert(); }); t += 950;
    new Timer(new Duration(milliseconds: t), () { snap('editor_revert'); }); t += 450;
    // Validated gate (syntax-check-first): a BAD edit is REJECTED before any write
    // or reload — wsCheckSyntax catches it, so the live instance AND the DB are
    // untouched and the next boot stays safe.
    new Timer(new Duration(milliseconds: t), () {
      ui.set('ed_source', {'text': wr('class Counter {\n  int n = 0\n  this is not valid dart\n}')});
      ui.commit();
      currentEditClass = 'Counter';
      accept();   // -> wsCheckSyntax rejects; no DB write, no reload
    }); t += 600;
    new Timer(new Duration(milliseconds: t), () { snap('editor_reject'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { switchTab(7); refreshVM(); snap('tab_vm'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { switchTab(3); ui.set('fd_q', {'text': 'Codec'}); ui.commit(); doFind(); snap('tab_find'); }); t += 450;
    // App: build the keypad in one tick; press + snapshot in the NEXT (a full
    // message-loop cycle between materialize and PrintWindow so every freshly
    // created button has painted at least once before the snapshot).
    new Timer(new Duration(milliseconds: t), () {
      switchTab(5);
      var keys = ui.widgetIds.where((s) => s.length >= 1 && s[0] == 'k').length;
      print('APP: keypad built, $keys key widgets');
    }); t += 450;
    new Timer(new Duration(milliseconds: t), () {
      // The App pane's keypad is a SMALLTALK app materialised over the C4
      // 'appui' bridge (buildApp -> ask('appbuild')), so `calc` is only non-null
      // once `ui apprun <StClass>` has started one. Driving it unconditionally
      // threw NoSuchMethodError on null and killed the UI isolate, aborting every
      // later step (including the game-pane captures). Guard it: exercise the
      // keypad when an app is live, always snapshot the tab.
      if (calc != null) {
        calc.press('7', ui); calc.press('+', ui); calc.press('5', ui); calc.press('=', ui);  // -> 12
        print('APP: 7+5= -> keypad driven');
      } else {
        print('APP: no live app (needs `ui apprun <StClass>`); snapshotting empty pane');
      }
      ui.commit();
      snap('tab_app');
    }); t += 450;
    // Tab-clear regression: RE-VISIT App (a 2nd build) then switch away. The keypad
    // must NOT bleed onto the next tab (ui.remove now drops ids from the ticket map,
    // so buildApp's before/after widgetIds diff tracks the keypad on every visit).
    new Timer(new Duration(milliseconds: t), () { switchTab(6); }); t += 350;   // Debug
    new Timer(new Duration(milliseconds: t), () { switchTab(5); }); t += 350;   // App AGAIN
    new Timer(new Duration(milliseconds: t), () {
      switchTab(1);                        // -> Browser (gappy: any keypad bleed shows)
      var kcount = ui.widgetIds.where((s) => s.length >= 1 && s[0] == 'k').length;
      print('REVISIT: keypad widgets after leaving App = $kcount (0 = destroyed, not hidden)');
    }); t += 250;
    new Timer(new Duration(milliseconds: t), () { snap('tab_revisit'); }); t += 450;  // Browser — must be clean
    new Timer(new Duration(milliseconds: t), () { switchTab(4); selectDocsClass(docIdx); snap('tab_docs'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { switchTab(8); snap('tab_help'); }); t += 450;
    // Debug: open the tab, run one scripted debug session (breakpoint -> pause ->
    // stack -> frame-eval -> step -> resume -> complete), let it settle, snapshot.
    new Timer(new Duration(milliseconds: t), () { switchTab(6); debugRun(0); }); t += 1800;
    new Timer(new Duration(milliseconds: t), () { snap('tab_debug'); }); t += 450;
    // Polish captures: FULL window (frame + menu bar + toolbar + client). Build the
    // tab in one tick, snapshot in the NEXT (a message-loop cycle so removed widgets'
    // areas repaint/erase before PrintWindow — no stale pixels from a taller tab).
    new Timer(new Duration(milliseconds: t), () { dispatchMenu(202); }); t += 450;   // -> Editor (via menu id)
    new Timer(new Duration(milliseconds: t), () {
      var e = wsSnapshotFull(outPng('polish_editor'));
      print('SNAP: polish_editor ${e.isEmpty ? "OK" : "ERR:$e"}');
    }); t += 450;
    new Timer(new Duration(milliseconds: t), () { switchTab(1); }); t += 450;        // -> Browser (rich overview)
    new Timer(new Duration(milliseconds: t), () {
      var e = wsSnapshotFull(outPng('polish_overview'));
      print('SNAP: polish_overview ${e.isEmpty ? "OK" : "ERR:$e"}');
    }); t += 450;

    // ── Item 1 proof: fire commands through the REAL toolbar path ─────────────
    // wsFireCommand synthesizes the exact WM_COMMAND an icon-toolbar button posts
    // (lParam == toolbar HWND), so this exercises WndProc -> OnMenuCommand ->
    // host queue -> pollMenu -> dispatchMenu — the whole chain, not just Dart.
    var navA = classNames.indexOf('Duration'); if (navA < 0) navA = 0;
    var navB = classNames.indexOf('StringBuffer');
    if (navB < 0) navB = (classNames.length > 1 ? 1 : 0);
    // Do-It from the toolbar: set a distinctive expression, then fire CMD_DOIT.
    new Timer(new Duration(milliseconds: t), () {
      switchTab(0); ui.set('ws_editor', {'text': '111 + 222'}); ui.commit();
    }); t += 450;
    new Timer(new Duration(milliseconds: t), () { wsFireCommand(140); pollMenu(); }); t += 450; // CMD_DOIT
    new Timer(new Duration(milliseconds: t), () { snap('toolbar_doit'); }); t += 450;
    // Browser Back from the toolbar: reset history, visit two classes, fire CMD_BACK.
    new Timer(new Duration(milliseconds: t), () {
      switchTab(1);
      browseHistory = <int>[]; browseCursor = -1;   // deterministic proof
      selectClass(navA); selectClass(navB);
      print('NAV setup: A=${classNames[navA]} B=${classNames[navB]} hist=$browseHistory cur=$browseCursor');
    }); t += 450;
    new Timer(new Duration(milliseconds: t), () { wsFireCommand(146); pollMenu(); }); t += 450; // CMD_BACK -> class A
    new Timer(new Duration(milliseconds: t), () { snap('toolbar_back'); }); t += 450;
    // Home from the toolbar: fire CMD_HOME -> Browser top class.
    new Timer(new Duration(milliseconds: t), () { wsFireCommand(145); pollMenu(); }); t += 450; // CMD_HOME
    new Timer(new Duration(milliseconds: t), () { snap('toolbar_home'); }); t += 450;

    // ── Item 2 proof: resize the real OS window; the Browser reflows to fill ──
    new Timer(new Duration(milliseconds: t), () { switchTab(1); selectClass(navA); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { wsResizeWindow(1460, 940); }); t += 500;  // WM_SIZE -> onResize
    new Timer(new Duration(milliseconds: t), () { snap('resize_large'); }); t += 500;
    new Timer(new Duration(milliseconds: t), () { wsResizeWindow(820, 560); }); t += 500;
    new Timer(new Duration(milliseconds: t), () { snap('resize_small'); }); t += 500;
    new Timer(new Duration(milliseconds: t), () { wsResizeWindow(1100, 800); }); t += 450;  // restore

    // ── The BILINGUAL browser: Smalltalk classes beside the Dart ones ────────
    // Deliberately LATE in the sequence. The ST world import is asynchronous and
    // lands in two stages — "imported N classes" (the loader finished) and only
    // then "N Smalltalk classes browsable" (the `smalltalk` library becomes
    // visible to the browser). Running this right after the import reported a
    // spurious miss. Point WINDART_ST_WORLD at a world to populate it.
    new Timer(new Duration(milliseconds: t), () {
      switchTab(1);
      var si = libraryNames.indexOf('smalltalk');
      if (si >= 0) {
        selectLibrary(si);
        print('ST-BROWSE: smalltalk -> ${libClasses.length} classes');
      } else if (_stClasses.isEmpty) {
        print('ST-BROWSE: no world configured (set WINDART_ST_WORLD)');
      } else {
        print('ST-BROWSE: world loaded (${_stClasses.length}) but library not '
              'listed yet — import still settling');
      }
    }); t += 500;
    new Timer(new Duration(milliseconds: t), () { snap('browser_smalltalk'); }); t += 450;
    // …and drill into one: a real ST class with its real .mst source.
    new Timer(new Duration(milliseconds: t), () {
      var ci = libClasses.indexOf('Fraction');
      if (ci < 0 && libClasses.isNotEmpty) ci = 0;
      if (ci >= 0) { selectLibClass(ci); print('ST-BROWSE: class ${libClasses[ci]}'); }
    }); t += 500;
    new Timer(new Duration(milliseconds: t), () { snap('browser_smalltalk_class'); }); t += 450;

    // ── Game tab: spawn a gp game in its OWN isolate, let it render frames into
    // the D3D11 pane, capture the HONEST frames (gpSnap = offscreen RT, gpSnapPresent
    // = on-screen swapchain — both independent of PrintWindow), then drive the
    // selector to a second game, then leave (stopGame must shut the isolate cleanly).
    new Timer(new Duration(milliseconds: t), () { switchTab(9); print('GAME: -> Game tab, spawning $gameSel'); }); t += 2200;
    new Timer(new Duration(milliseconds: t), () {
      print('GAME: $gameSel frames=$gameFrames opened=$gameOpened');
      var a = gpSnap(outPng('game_pane'));
      var b = gpSnapPresent(outPng('game_present'));
      print('GAME: gpSnap ${a.isEmpty ? "OK" : "ERR:$a"}  gpSnapPresent ${b.isEmpty ? "OK" : "ERR:$b"}');
      snap('tab_game');
    }); t += 450;
    // Selector proof + tile-layers on-screen: switch to tiletest via startGame,
    // capture BOTH offscreen (gpSnap) and the live swapchain (gpSnapPresent).
    new Timer(new Duration(milliseconds: t), () { startGame('tiletest'); print('GAME: -> tiletest'); }); t += 2200;
    new Timer(new Duration(milliseconds: t), () {
      print('GAME: tiletest frames=$gameFrames');
      var a = gpSnap(outPng('game_tiletest'));
      var b = gpSnapPresent(outPng('game_tiletest_present'));
      print('GAME: tiletest gpSnap ${a.isEmpty ? "OK" : "ERR:$a"}  present ${b.isEmpty ? "OK" : "ERR:$b"}');
    }); t += 450;
    // Leaving the Game tab must stop the isolate cleanly (no crash, no bleed).
    new Timer(new Duration(milliseconds: t), () { switchTab(1); print('GAME: left Game tab -> stopGame done=$gameDone'); }); t += 450;
    new Timer(new Duration(milliseconds: t), () { snap('tab_after_game'); }); t += 450;

    new Timer(new Duration(milliseconds: t), () { print('SELFTEST: done'); hostQuit(); });
  }
  // else: stay open — a real interactive application.
}
