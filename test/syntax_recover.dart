// WINDARTARM AS3 — the longjmp/SEH recovery probe (arm64 plan risk 6).
//
// windart-port.patch changes runtime/vm/longjump.cc: under _MSC_VER it SKIPS
// StackResource::UnwindAbove, because MSVC's longjmp() performs SEH stack
// unwinding which already runs the StackResource destructors — doing both
// destructs them twice and trips ~StackResource's ASSERT(top == this),
// ABORTING the VM on any scan/parse error. That fix was verified on x64.
//
// Windows arm64 also uses table-driven SEH and its longjmp also unwinds, so the
// _MSC_VER gate should remain correct with no arm64-specific change — but
// "should" is why this test exists. A scan/parse error must be REPORTED
// (catchable, process survives) and never abort.
//
// Covers three flavours of source-level failure, all of which funnel through
// the Scanner/Parser -> LongJump path:
//   1. a stray UTF-8 BOM      (the scanner.cc hunk in windart-port.patch)
//   2. a hard syntax error    (parser LongJump)
//   3. an unresolved import   (loader error)
// Each is loaded via wsCheckSyntax(), which uses Dart_LoadLibrary +
// Dart_FinalizeLoading + Dart_EvaluateExpr — embedder APIs that RETURN the
// error instead of propagating it.
import 'dart:win';

int _checks = 0;
int _fails = 0;

void expectError(String label, String src, String cls) {
  _checks++;
  String err = wsCheckSyntax(src, cls);
  if (err == '') {
    print('SEH: $label -> NO ERROR REPORTED (expected one)');
    _fails++;
  } else {
    String oneLine = err.replaceAll('\n', ' ');
    if (oneLine.length > 96) oneLine = oneLine.substring(0, 96) + '...';
    print('SEH: $label -> reported OK: $oneLine');
  }
}

void expectOk(String label, String src, String cls) {
  _checks++;
  String err = wsCheckSyntax(src, cls);
  if (err != '') {
    print('SEH: $label -> unexpected error: ${err.replaceAll("\n", " ")}');
    _fails++;
  } else {
    print('SEH: $label -> compiled clean');
  }
}

main() {
  // Baseline: the machinery works at all and a good class compiles.
  expectOk('valid class', 'class Ok { int n = 1; }', 'Ok');

  // 1. Leading UTF-8 BOM (U+FEFF). Pre-patch this faulted during load at
  //    allocation.cc:37; the scanner.cc hunk skips it. Must compile CLEAN.
  expectOk('leading BOM', '﻿class Bom { int n = 2; }', 'Bom');

  // 2. Hard syntax errors -> parser LongJump -> longjmp -> SEH unwind.
  expectError('missing brace', 'class Bad1 { int n = 1;', 'Bad1');
  expectError('garbage token', 'class Bad2 { int n = @@@; }', 'Bad2');
  expectError('unclosed string', 'class Bad3 { var s = "unterminated; }', 'Bad3');
  expectError('bad member', 'class Bad4 { void () {} }', 'Bad4');

  // 3. Unresolved import -> loader error path.
  expectError('missing import',
      'import "package:nope/nope.dart";\nclass Bad5 { int n = 1; }', 'Bad5');

  // Recovery: after all that longjmp traffic the isolate must still be healthy
  // and the JIT must still produce correct code.
  expectOk('valid after errors', 'class Ok2 { int n = 3; }', 'Ok2');
  int acc = 0;
  for (int i = 1; i <= 1000; i++) acc += i;
  if (acc != 500500) {
    print('SEH: post-error arithmetic wrong: $acc');
    _fails++;
  }

  print('SEH: $_checks checks, $_fails failures');
  print(_fails == 0 ? 'SEH_OK' : 'SEH_FAIL');
}
