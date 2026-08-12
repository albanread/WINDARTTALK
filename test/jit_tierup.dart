// WINDARTARM AS2 exit probe — force optimizing tier-up on arm64.
// A function hot enough to cross the usage counter (~30k invocations at
// default thresholds) gets recompiled by the OPTIMIZING arm64 backend; with
// --compiler_stats the VM reports functions compiled/optimized at exit.
int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);

main() {
  int acc = 0;
  for (int i = 0; i < 200; i++) {
    acc += fib(20);
  }
  print('fib(20) x200 -> $acc');   // 200 * 6765 = 1353000
}
