// windart ST M3 world-exercise — boot the full world, then drive the loaded
// library (collections/streams/numbers/Fraction) to prove it is FUNCTIONAL,
// not merely loadable. Each line prints its real answer via Transcript (stdout).
//
//   dart.exe st_world_run.dart <world-dir>
import 'dart:cocoa';
import 'dart:io';

main(List<String> args) {
  var dir = args.isEmpty ? '.' : args[0];
  var files = new Directory(dir).listSync()
      .map((e) => e.path).where((p) => p.endsWith('.mst')).toList()..sort();
  for (var p in files) {
    var r = stRun(new File(p).readAsStringSync());
    if (r.toString().startsWith('ERR')) { print('BOOT FAIL $p'); exit(1); }
  }
  print('world booted (${files.length} files)\n--- exercising the loaded library ---');

  void ex(String label, String code) {
    stdout.write('${label.padRight(14)} ');
    var r = stRun(code);
    if (r.toString().startsWith('ERR')) print('ERR ${r.toString().split("\n").first}');
  }

  ex('OrderedColl', "Transcript showCr: ((OrderedCollection new add: 1; add: 2; add: 3; yourself) inject: 0 into: [:a :b | a + b]) printString.");
  ex('Dictionary', "| d | d := Dictionary new. d at: #a put: 10. d at: #b put: 20. Transcript showCr: ((d at: #a) + (d at: #b)) printString.");
  ex('Set dedup', "Transcript showCr: ((Set new add: 1; add: 1; add: 2; yourself) size) printString.");
  ex('Interval', "Transcript showCr: ((1 to: 100) inject: 0 into: [:a :b | a + b]) printString.");
  ex('SortedColl', "| s | s := SortedCollection new. s add: 3; add: 1; add: 2. Transcript showCr: s first printString, '..', s last printString.");
  ex('Fraction', "Transcript showCr: ((1/2) + (1/3)) printString.");
  ex('WriteStream', "| w | w := WriteStream on: String new. w nextPutAll: 'hello '; nextPutAll: 'world'. Transcript showCr: w contents.");
  ex('String map', "Transcript showCr: ('hello' collect: [:c | c asUppercase]).");
  ex('inject/select', "Transcript showCr: (((1 to: 10) select: [:n | n even]) inject: 0 into: [:a :b | a + b]) printString.");
}
