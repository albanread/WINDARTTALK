// windart-ST feature battery — boot the world, load the STest framework + every
// feature suite, run each suite and sum failures. The suites hammer class-side
// sends (OrderedCollection new, Set new, Dictionary new, Array with:with:, self
// new), so a green battery also gates the class-side DECISION cache.
//   dart.exe st_battery.dart <world-dir> <features-dir>
import 'dart:cocoa';
import 'dart:io';

List<String> mstFiles(String dir) => new Directory(dir)
    .listSync()
    .map((e) => e.path)
    .where((p) => p.endsWith('.mst'))
    .toList()
  ..sort();

main(List<String> args) {
  var world = args[0];
  var feat = args[1];

  // 1) boot the world (every class defined here via class-side sends)
  for (var p in mstFiles(world)) {
    var r = stRun(new File(p).readAsStringSync());
    if (r.toString().startsWith('ERR')) {
      print('BOOT FAIL ' + p + ': ' + r.toString());
      exit(2);
    }
  }
  print('world booted');

  // 2) framework.mst must load before its subclasses
  var files = mstFiles(feat);
  files.sort((a, b) {
    var fa = a.contains('framework') ? 0 : 1;
    var fb = b.contains('framework') ? 0 : 1;
    return fa != fb ? fa - fb : a.compareTo(b);
  });
  var re = new RegExp(r'STestCase subclass: ([A-Za-z0-9]+)');
  var classes = <String>[];
  for (var p in files) {
    var src = new File(p).readAsStringSync();
    var r = stRun(src);
    if (r.toString().startsWith('ERR')) {
      print('LOAD FAIL ' + p + ': ' + r.toString());
      exit(2);
    }
    for (var m in re.allMatches(src)) classes.add(m.group(1));
  }

  // 3) run each suite. `runSuite` (instance side) answers the failure count
  // directly through stSend — stRun of a do-it returns a loader message, not the
  // expression value, so send the selector instead (as st_cogbench does).
  var totalFail = 0, suites = 0;
  for (var c in classes) {
    var r = stSend(stNew(c), 'runSuite', []);
    var n = (r is int) ? r : int.parse(r.toString().trim(), onError: (_) => -1);
    if (n < 0) {
      print('  ERR   ' + c + ' -> "' + r.toString() + '"');
      totalFail++;
    } else {
      print('  ' + (n == 0 ? 'ok   ' : 'FAIL ') + c + '  (' + n.toString() + ' fail)');
      totalFail += n;
    }
    suites++;
  }
  print('\nBATTERY: ' + suites.toString() + ' suites, ' + totalFail.toString() + ' failures');
  exit(totalFail == 0 ? 0 : 1);
}
