// windart-ST cog-bench (FAIR methodology) — same 7 workloads as Cog + WINVM,
// but driven like run_macdart.dart: a warmed wrapper class whose instance
// methods are pre-compiled and JIT-optimized by warmup, then timed via stSend
// (NOT a recompiled do-it, which would run the outer loop unoptimized). 10x
// inner per sample to match the cog-bench protocol; best of 7 warm samples.
//
//   dart.exe st_cogbench.dart <world-dir>
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
  stRun("Object subclass: CB [ "
      "arith [ ^BenchmarkDashboard benchArith ] "
      "fib [ ^BenchmarkDashboard benchFib ] "
      "sieve [ ^BenchmarkDashboard benchSieve ] "
      "dict [ ^BenchmarkDashboard benchDict ] "
      "alloc [ ^BenchmarkDashboard benchAlloc ] "
      "richards [ ^BenchmarkDashboard benchRichards ] "
      "deltablue [ ^BenchmarkDashboard benchDeltaBlue ] ]");
  var cb = stNew('CB');
  print('world booted (${files.length}) — windart-ST, warmed stSend, 10x inner, best of 7\n');

  void bench(String name, String sel) {
    for (var i = 0; i < 40; i++) stSend(cb, sel, []);   // warm -> optimized JIT
    var best = 1 << 30;
    for (var s = 0; s < 7; s++) {
      var sw = new Stopwatch()..start();
      for (var k = 0; k < 10; k++) stSend(cb, sel, []);
      sw.stop();
      if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
    }
    print('$name warm_us=$best   (${(best / 1000).toStringAsFixed(1)} ms)');
  }

  bench('arith    ', 'arith');
  bench('fib      ', 'fib');
  bench('sieve    ', 'sieve');
  bench('dict     ', 'dict');
  bench('alloc    ', 'alloc');
  bench('richards ', 'richards');
  bench('deltablue', 'deltablue');
}
