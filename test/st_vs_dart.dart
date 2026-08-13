// st_vs_dart.dart -- paired ST/Dart micro-benchmarks that isolate each control-flow
// form the ST front-end lowers, so a codegen change can be judged form by form
// rather than by one aggregate number.
//
// Every workload is written TWICE with identical semantics: once in Smalltalk
// (compiled by port-win/dart_st/st_flow_graph_builder.cc into Dart flow-graph IR)
// and once in plain Dart (compiled by the VM's own AST front-end). Both sides are
// warmed to the optimizing JIT, then timed best-of-N. The ratio is the number that
// matters: the ST front-end should land NEAR 1.0x, not multiples.
//
// Baseline before any comparison-lowering work (Windows ARM64, Snapdragon Oryon):
//   mandel 5.24x -- see port-arm64/PERF_ST_VS_DART.md
//
//   dart.exe st_vs_dart.dart <world-dir>
import 'dart:cocoa';
import 'dart:io';

const int WARM = 8, SAMPLES = 5;

// ---------------------------------------------------------------- Dart side --
// Each returns an accumulator so nothing can be optimized away as dead.

int dartLoopCmp(int n) {
  int i = 0;
  while (i < n) { i = i + 1; }
  return i;
}

double dartSumDbl(int n) {
  int i = 0;
  double s = 0.0;
  while (i < n) { s = s + 1.5; i = i + 1; }
  return s;
}

int dartNestIf(int n) {
  int i = 0, a = 0;
  while (i < n) {
    if (i < 500) { a = a + 1; } else { a = a + 2; }
    i = i + 1;
  }
  return a;
}

// NB: the guard must NOT trip early or the loop exits after a few thousand
// iterations and the row measures nothing (an earlier version overflowed `a`
// past 2e9 within ~63k iterations and reported a meaningless 1.51x).
int dartAndOr(int n) {
  int i = 0, a = 0;
  while ((i < n) && (i < 2000000000)) { a = a + 1; i = i + 1; }
  return a;
}

// Double-valued comparison in the loop condition, at scale.
double dartDblCmp(double lim) {
  double x = 0.0;
  while (x < lim) { x = x + 1.0; }
  return x;
}

// Reading the bound from a FIELD each iteration rather than a local.
class Bound {
  var limit;          // deliberately untyped, like an ST instance variable
  Bound(this.limit);
  int run() { int i = 0; while (i < limit) { i = i + 1; } return i; }
}

// The escape loop with the iteration cap as a LOCAL (not a field).
int dartEscapeLocal(double cr, double ci) {
  double zr = 0.0, zi = 0.0, zr2 = 0.0, zi2 = 0.0;
  int n = 0, mx = 150;
  while ((zr2 + zi2 < 4.0) && (n < mx)) {
    zi = (2.0 * zr * zi) + ci;
    zr = (zr2 - zi2) + cr;
    zr2 = zr * zr;
    zi2 = zi * zi;
    n = n + 1;
  }
  return n;
}

// 40k calls of a full-depth (interior point => all 150 iterations) escape.
int dartEscapeBulk(bool local) {
  int acc = 0;
  for (int k = 0; k < 40000; k++) {
    acc += local ? dartEscapeLocal(-0.5, 0.0) : dartEscape(-0.5, 0.0, 150);
  }
  return acc;
}

int dartToDo(int n) {
  int a = 0;
  for (int i = 1; i <= n; i++) { a = a + i; }
  return a;
}

int dartEscape(double cr, double ci, int maxIter) {
  double zr = 0.0, zi = 0.0, zr2 = 0.0, zi2 = 0.0;
  int n = 0;
  while ((zr2 + zi2 < 4.0) && (n < maxIter)) {
    zi = (2.0 * zr * zi) + ci;
    zr = (zr2 - zi2) + cr;
    zr2 = zr * zr;
    zi2 = zi * zi;
    n = n + 1;
  }
  return n;
}

int dartMandel() {
  double scale = 3.5, stepc = 3.5 / 320.0;
  double rmin = -0.743643887037151 - (scale / 2.0);
  double imin = 0.131825904205330 - ((240.0 * stepc) / 2.0);
  int acc = 0;
  for (int py = 0; py <= 239; py++) {
    double ci = imin + (py.toDouble() * stepc);
    double cr = rmin;
    for (int px = 0; px <= 319; px++) {
      acc = acc + dartEscape(cr, ci, 150);
      cr = cr + stepc;
    }
  }
  return acc;
}

// ------------------------------------------------------------------ ST side --
// NB: '\\' is the ST modulo selector; in a Dart string literal it is '\\\\'.
const String ST_CLASS = """
Object subclass: SvD [
    | mb limit |
    initMb [ mb := Mandelbrot new maxIter: 150. ^self ]

    loopCmp: n [ | i | i := 0. [ i < n ] whileTrue: [ i := i + 1 ]. ^i ]

    sumDbl: n [ | i s | i := 0. s := 0.0.
        [ i < n ] whileTrue: [ s := s + 1.5. i := i + 1 ]. ^s ]

    nestIf: n [ | i a | i := 0. a := 0.
        [ i < n ] whileTrue: [
            i < 500 ifTrue: [ a := a + 1 ] ifFalse: [ a := a + 2 ].
            i := i + 1 ]. ^a ]

    andOr: n [ | i a | i := 0. a := 0.
        [ (i < n) and: [ i < 2000000000 ] ] whileTrue: [ a := a + 1. i := i + 1 ]. ^a ]

    dblCmp: lim [ | x | x := 0.0. [ x < lim ] whileTrue: [ x := x + 1.0 ]. ^x ]

    boundIvar: n [ limit := n. ^self runBound ]
    runBound [ | i | i := 0. [ i < limit ] whileTrue: [ i := i + 1 ]. ^i ]

    "Same escape loop as Mandelbrot>>escapeAtRe:im: but the cap is a LOCAL,
     not an instance variable -- isolates the field read from the arithmetic."
    escapeLocalRe: cr im: ci [
        | zr zi zr2 zi2 n mx |
        mx := 150.
        zr := 0.0. zi := 0.0. zr2 := 0.0. zi2 := 0.0. n := 0.
        [ (zr2 + zi2 < 4.0) and: [ n < mx ] ] whileTrue: [
            zi := (2.0 * zr * zi) + ci.
            zr := (zr2 - zi2) + cr.
            zr2 := zr * zr.
            zi2 := zi * zi.
            n := n + 1 ].
        ^n ]

    "40k full-depth escapes (interior point => all 150 iterations)."
    escapeIvarBulk [ | acc | acc := 0.
        1 to: 40000 do: [ :k | acc := acc + (mb escapeAtRe: -0.5 im: 0.0) ]. ^acc ]
    escapeLocalBulk [ | acc | acc := 0.
        1 to: 40000 do: [ :k | acc := acc + (self escapeLocalRe: -0.5 im: 0.0) ]. ^acc ]

    toDo: n [ | a | a := 0. 1 to: n do: [ :i | a := a + i ]. ^a ]

    mandel [ | stepc rmin imin ci cr acc scale |
        scale := 3.5.
        stepc := scale / 320.0.
        rmin := (0.0 - 0.743643887037151) - (scale / 2.0).
        imin := 0.131825904205330 - ((240.0 * stepc) / 2.0).
        acc := 0.
        0 to: 239 do: [ :py |
            ci := imin + (py asDouble * stepc).
            cr := rmin.
            0 to: 319 do: [ :px |
                acc := acc + (mb escapeAtRe: cr im: ci).
                cr := cr + stepc ] ].
        ^acc ]
]
""";

main(List<String> args) {
  var dir = args.isEmpty ? '.' : args[0];
  var files = new Directory(dir).listSync()
      .map((e) => e.path).where((p) => p.endsWith('.mst')).toList()..sort();
  for (var p in files) {
    var r = stRun(new File(p).readAsStringSync());
    if (r.toString().startsWith('ERR')) { print('BOOT FAIL $p -> $r'); exit(1); }
  }
  var mk = stRun(ST_CLASS);
  if (mk.toString().startsWith('ERR')) { print('SvD compile FAIL -> $mk'); exit(1); }

  var o = stNew('SvD');
  stSend(o, 'initMb', []);   // stNew is basicNew -- initialise explicitly
  print('world booted (${files.length}) -- warmed, best of $SAMPLES\n');

  int timeIt(f()) {
    for (var i = 0; i < WARM; i++) f();
    var best = 1 << 30;
    for (var s = 0; s < SAMPLES; s++) {
      var sw = new Stopwatch()..start();
      f();
      sw.stop();
      if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
    }
    return best;
  }

  print('workload      ST(ms)   Dart(ms)   ratio   verdict');
  print('--------------------------------------------------');
  var ratios = <String, double>{};

  void row(String name, String sel, List stArgs, dartFn()) {
    var st = timeIt(() => stSend(o, sel, stArgs));
    var dt = timeIt(dartFn);
    var ratio = st / (dt == 0 ? 1 : dt);
    ratios[name] = ratio;
    var verdict = ratio <= 1.5 ? 'ok' : (ratio <= 2.5 ? 'meh' : 'SLOW');
    print('${name.padRight(12)} ${(st / 1000).toStringAsFixed(2).padLeft(7)} '
          '${(dt / 1000).toStringAsFixed(2).padLeft(10)} '
          '${ratio.toStringAsFixed(2).padLeft(7)}x   $verdict');
  }

  var bound = new Bound(10000000);
  row('loopCmp',  'loopCmp:', [10000000], () => dartLoopCmp(10000000));
  row('sumDbl',   'sumDbl:',  [10000000], () => dartSumDbl(10000000));
  row('nestIf',   'nestIf:',  [5000000],  () => dartNestIf(5000000));
  row('andOr',    'andOr:',   [10000000], () => dartAndOr(10000000));
  row('toDo',     'toDo:',    [10000000], () => dartToDo(10000000));
  row('dblCmp',   'dblCmp:',  [10000000.0], () => dartDblCmp(10000000.0));
  row('boundIvar','boundIvar:',[10000000], () => bound.run());
  row('escLocal', 'escapeLocalBulk', [], () => dartEscapeBulk(true));
  row('escIvar',  'escapeIvarBulk',  [], () => dartEscapeBulk(false));
  row('mandel',   'mandel',   [],         dartMandel);

  var worst = 0.0, worstName = '';
  var sum = 0.0;
  ratios.forEach((k, v) { sum += v; if (v > worst) { worst = v; worstName = k; } });
  print('--------------------------------------------------');
  print('mean ratio ${(sum / ratios.length).toStringAsFixed(2)}x   '
        'worst $worstName ${worst.toStringAsFixed(2)}x');
}
