// WINDARTARM AS3 — the i-cache churn probe (arm64 plan risk 1).
//
// arm64's instruction cache is NOT coherent with the data cache. On x64
// CPU::FlushICache is a documented no-op; on arm64 every JIT emission and every
// code_patcher_arm64 self-modification must be published to the i-cache or the
// CPU may execute STALE BYTES. This test manufactures that hazard on purpose,
// hundreds of times, and checks the answer each round:
//
//   for each round i:
//     1. rewrite churn_target.dart so its functions return `i`
//     2. wsReload()  -> Dart_WorkspaceReloadSources: recompile + re-patch every
//        call site into the reloaded library (self-modifying arm64 code)
//     3. HAMMER churnHot() so the OPTIMIZING arm64 backend recompiles it at a
//        fresh address and the inline caches / static calls get patched again
//     4. assert churnValue() == i  and  churnHot(k) == k + i
//
// A missing/late i-cache flush shows up as a wrong value (stale code returning
// the PREVIOUS round's constant) or a crash. Silence is the pass condition.
//
// Run (sharper: force optimisation every round):
//   dart.exe --optimization_counter_threshold=100 test\reload_churn.dart [rounds]
import 'dart:io';
import 'dart:win';
import 'churn_target.dart' as t;

const String _v0 =
    '// WINDARTARM AS3 — the hot-reload churn target. REWRITTEN IN PLACE by\n'
    '// reload_churn.dart on every iteration, then restored to this v0 state when the\n'
    '// run finishes. If you find it holding some other value, a churn run died early.\n'
    'int churnValue() => 0;\n'
    'int churnHot(int x) => x + 0;\n';

main(List<String> args) {
  int rounds = args.isEmpty ? 500 : int.parse(args[0]);
  // calls/round: enough to cross a lowered opt threshold. args[1] overrides so
  // the JIT variable can be separated from the reload variable during triage.
  int hammer = args.length > 1 ? int.parse(args[1]) : 400;

  String here = Platform.script.toFilePath();
  String dir = here.substring(0, here.lastIndexOf(Platform.pathSeparator));
  File target = new File('$dir${Platform.pathSeparator}churn_target.dart');

  int reloadErrors = 0;
  int staleValue = 0;
  int staleHot = 0;
  String firstFailure = null;

  print('CHURN: $rounds rounds x $hammer calls, target = ${target.path}');
  var sw = new Stopwatch()..start();

  for (int i = 1; i <= rounds; i++) {
    if (rounds <= 30 || i % 10 == 0) print('CHURN: >>> round $i start');
    target.writeAsStringSync(
        'int churnValue() => $i;\n'
        'int churnHot(int x) => x + $i;\n');

    String err = wsReload();
    if (err != '') {
      reloadErrors++;
      if (firstFailure == null) firstFailure = 'round $i reload: $err';
      continue;
    }

    // Force the optimising backend to recompile the freshly-reloaded function
    // and re-patch its call sites — the actual self-modifying-code hazard.
    if (hammer > 0) {
      int acc = 0;
      for (int k = 0; k < hammer; k++) acc = t.churnHot(k);
      int wantHot = (hammer - 1) + i;
      if (acc != wantHot) {
        staleHot++;
        if (firstFailure == null) {
          firstFailure = 'round $i churnHot: got $acc want $wantHot (STALE CODE)';
        }
      }
    }

    int got = t.churnValue();
    if (got != i) {
      staleValue++;
      if (firstFailure == null) {
        firstFailure = 'round $i churnValue: got $got want $i (STALE CODE)';
      }
    }
  }

  sw.stop();
  target.writeAsStringSync(_v0);   // leave the tree as we found it

  print('CHURN: ${sw.elapsedMilliseconds} ms  '
        '(${(sw.elapsedMilliseconds / rounds).toStringAsFixed(1)} ms/round)');
  print('CHURN: reloadErrors=$reloadErrors staleValue=$staleValue staleHot=$staleHot');
  if (firstFailure != null) {
    print('CHURN: first failure -> $firstFailure');
    print('CHURN_FAIL');
    exit(1);
  }
  print('CHURN_OK');
}
