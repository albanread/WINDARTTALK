// Boot the world, then run ONE BenchmarkDashboard selector N times — for
// isolating a single workload under VM tracing (deopt / compile).
//   dart.exe [--trace_deoptimization] st_one.dart <world-dir> <benchSel> <N>
import 'dart:cocoa';
import 'dart:io';

main(List<String> args) {
  var dir = args[0], sel = args[1];
  var n = args.length > 2 ? int.parse(args[2]) : 30;
  var files = new Directory(dir).listSync()
      .map((e) => e.path).where((p) => p.endsWith('.mst')).toList()..sort();
  for (var p in files) { stRun(new File(p).readAsStringSync()); }
  stderr.writeln('booted; running $sel x$n');
  for (var i = 0; i < n; i++) { stRun("BenchmarkDashboard $sel."); }
  stderr.writeln('done $sel');
}
