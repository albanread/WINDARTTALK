// windart Smalltalk M1 probe — prove ONE .mst method compiles + runs headless
// on the Dart x64 JIT. World-free: only dart:cocoa + the auto-loaded prelude,
// no --with-st, no world corpus, no FFI, no objc.
//
//   dart.exe st_probe.dart
//
// Exercises the whole pipeline: prelude-load -> ST class registration ->
// st::BuildGraph (the ported compiler) -> x64 JIT -> dynamic dispatch -> print.
import 'dart:cocoa';

main() {
  print("== windart ST M1 probe ==");

  // A bare Smalltalk do-it. `Transcript showCr:` is prelude-defined and falls
  // back to stdout when not GUI-hosted; `printString` + `*` exercise dispatch
  // and SmallInteger arithmetic (which lowers to the same Dart IL as native int).
  var r = stRun("Transcript showCr: (6 * 7) printString.");
  print("stRun returned: " + r.toString());

  // A second do-it with a temp + a keyword message, to exercise a local slot.
  var r2 = stRun("| x | x := 3 + 4. Transcript showCr: (x * x) printString.");
  print("stRun#2 returned: " + r2.toString());
}
