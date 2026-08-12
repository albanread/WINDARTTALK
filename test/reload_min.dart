// WINDARTARM AS3 triage — the MINIMAL reload repro.
//
// No file rewriting, no JIT hammering, no imports that change: just call
// wsReload() in a loop from inside a live Dart frame and count how far it gets.
// Isolates "how many reloads" from every other variable in reload_churn.dart.
//
//   dart.exe test\reload_min.dart [n]
import 'dart:win';

main(List<String> args) {
  int n = args.isEmpty ? 20 : int.parse(args[0]);
  print('MIN: attempting $n reloads from inside main()');
  for (int i = 1; i <= n; i++) {
    String err = wsReload();
    print('MIN: reload $i -> ${err == "" ? "ok" : err}');
  }
  print('MIN_OK');
}
