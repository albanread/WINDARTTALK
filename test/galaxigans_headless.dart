// Headless Galaxigans launch — boot the world, load the game, invoke launch.
// A GUI crash just closes the vm-service; headless, a native fault prints a
// stack, which is what we need to pinpoint where the port faults.
//   dart.exe galaxigans_headless.dart <world-dir> <galaxigans.mst>
import 'dart:cocoa';
import 'dart:io';

main(List<String> args) {
  var world = args[0], gx = args[1];
  var wf = new Directory(world).listSync()
      .map((e) => e.path).where((p) => p.endsWith('.mst')).toList()..sort();
  for (var p in wf) {
    var r = stRun(new File(p).readAsStringSync());
    if (r.toString().startsWith('ERR')) { print('BOOT FAIL ' + p + ': ' + r.toString()); exit(2); }
  }
  print('world booted (${wf.length})');
  var g = stRun(new File(gx).readAsStringSync());
  print('galaxigans load: ' + g.toString());

  // Drive setup only (not `run`, which would spin a frame loop). Reach the game
  // through its own class-side pieces to find the faulting step.
  print('--- new ---');    print(stRun('Galaxigans new. 42').toString());
  print('--- loadHall ---'); print(stRun('Galaxigans loadHall. 42').toString());
  print('--- buildSine ---'); print(stRun('Galaxigans buildSine. 42').toString());
  print('--- GamePane new ---'); print(stRun('GamePane new. 42').toString());
  print('--- FULL launch ---');
  print(stRun('Galaxigans launch. 42').toString());
  print('=== survived launch ===');
}
