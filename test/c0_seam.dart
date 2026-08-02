// C0 seam test — stand in for the UI isolate (workspace.dart is rebuilt later)
// and prove the bilingual brain works over the isolate wire, headless of any
// GUI. Spawns language.dart as the LANGUAGE isolate, then drives Do It.
//   dart.exe test/c0_seam.dart workspace/language.dart
import 'dart:isolate';
import 'dart:io';
import 'dart:async';

SendPort _lang; // the language isolate's command port

Future ask(String verb, arg) {
  var reply = new ReceivePort();
  _lang.send([verb, arg, reply.sendPort]);
  return reply.first;
}

main(List<String> argv) async {
  var langSrc = argv.isNotEmpty ? argv[0] : 'workspace/language.dart';
  // language.dart rewrites its own scratch file on a hot reload; hand it a copy.
  var scratch = new File(Directory.systemTemp.path + '/lang_scratch_c0.dart');
  scratch.writeAsStringSync(new File(langSrc).readAsStringSync());

  var ui = new ReceivePort();
  var ready = new Completer();
  ui.listen((msg) {
    if (_lang == null && msg is SendPort) {
      _lang = msg;
      ready.complete();
    } else if (msg is List && msg.isNotEmpty && msg[0] == 'tr') {
      stdout.writeln('  [transcript] ${msg[1]}');
    }
  });

  stdout.writeln('C0: spawning language isolate from ${scratch.path} ...');
  await Isolate.spawnUri(
      scratch.uri, <String>[scratch.path, '', '', ''], ui.sendPort);
  await ready.future;
  stdout.writeln('C0: language isolate UP — wire established.\n');

  for (var code in const [
    '25 sqrt', // ST unary (prelude) -> 5.0
    '#(1 2 3) size', // ST literal array -> 3
    'st> 6 * 7', // forced ST -> 42
    '(() => 6 * 7)()', // Dart: '=>' forces the wsEval path -> 42
    'List.filled(3, 9).length' // Dart: a call forces wsEval -> 3
  ]) {
    var out = await ask('doit', code);
    stdout.writeln('doit  ${code.padRight(18)} =>  $out');
  }
  stdout.writeln('\nC0 gate: bilingual Do It over the wire.');
  exit(0);
}
