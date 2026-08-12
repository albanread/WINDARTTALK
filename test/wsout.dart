// WINDARTARM — shared output-path helper for the WINDART test drivers.
//
// The drivers used to default their PNG output to a hard-pinned `e:\windart\...`
// path, which only existed on the original author's machine. Everything here is
// derived from where the calling script lives, so a driver works from any
// checkout on any machine. Expected layout:
//
//   <workRoot>/WINDARTTALK/test/<driver>.dart   <- the caller
//   <workRoot>/shots/                           <- default output
//
// Override the output directory with the WINDART_OUT environment variable.
// Mirrors the same helpers inlined at the top of test/workspace.dart.
library wsout;

import 'dart:io';

String _dirOf(String p) {
  var i = p.lastIndexOf('/'), j = p.lastIndexOf(r'\');
  var k = i > j ? i : j;
  return k > 0 ? p.substring(0, k) : p;
}

/// The directory holding the running script (…/WINDARTTALK/test).
final String scriptDir = _dirOf(Platform.script.toFilePath());

/// The repo root (…/WINDARTTALK).
final String repoRoot = _dirOf(scriptDir);

/// The work root that contains the repo, the extracted tree and the quarry.
final String workRoot = _dirOf(repoRoot);

/// Where captures go: $WINDART_OUT, else <workRoot>/shots. Created on demand.
final String outDir = () {
  var o = Platform.environment['WINDART_OUT'];
  var d = (o != null && o.trim().isNotEmpty) ? o.trim() : '$workRoot/shots';
  try {
    new Directory(d).createSync(recursive: true);
  } catch (e) {}
  return d;
}();

/// A PNG path inside the output directory. `outPng('pong')` -> `<out>/pong.png`.
String outPng(String name) => '$outDir/$name.png';

/// Resolve a path relative to the RUNNING SCRIPT — not the current working
/// directory — as a Uri suitable for `Isolate.spawnUri`.
///
/// The drivers used to spawn games with `Uri.parse('demos/$game.dart')`, which
/// is CWD-relative and therefore only worked when launched from `test/`. Use
/// `sibling('demos/$game.dart')` instead so a driver runs from anywhere.
/// (`Uri.parse` on an absolute Windows path is also wrong — it would read the
/// drive letter as a URI scheme — which is why this resolves against
/// `Platform.script` rather than building a string.)
Uri sibling(String relative) => Platform.script.resolve(relative);
