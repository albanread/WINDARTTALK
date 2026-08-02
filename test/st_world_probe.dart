// windart ST M3 world-boot probe — stRun every world .mst in name order and
// report which load cleanly vs ERR/throw. Replicates st::BootWorldForMain via
// the proven world-free path (no --with-st needed) so I can categorize the
// corpus into the bootable core vs the GUI/FFI/objc tail without a VM rebuild.
//
//   dart.exe st_world_probe.dart <world-dir>
import 'dart:cocoa';
import 'dart:io';

main(List<String> args) {
  var dir = args.isEmpty ? '.' : args[0];
  var files = new Directory(dir).listSync()
      .map((e) => e.path).where((p) => p.endsWith('.mst')).toList()..sort();
  var loaded = 0, failed = 0;
  var bad = [];
  for (var path in files) {
    var name = path.split(Platform.pathSeparator).last;
    var r;
    try {
      r = stRun(new File(path).readAsStringSync());
    } catch (e) {
      print('THREW  $name  ${e.toString().split("\n").first}');
      failed++; bad.add(name); continue;
    }
    if (r.toString().startsWith('ERR')) {
      print('ERR    $name  ${r.toString().split("\n").first}');
      failed++; bad.add(name);
    } else {
      loaded++;
    }
  }
  print('\n=== loaded $loaded, failed $failed of ${files.length} ===');
  print('bad: ${bad.join(" ")}');
}
