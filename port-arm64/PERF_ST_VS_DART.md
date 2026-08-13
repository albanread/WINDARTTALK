# ST at dartspeed — the relational-funnel poisoning, found and fixed

**Symptom.** MandelZoom crawled (~22 fps). A/B of the identical 320×240
escape-time frame, both sides warmed to the optimizing JIT, GPU excluded:
Smalltalk 44.3 ms vs Dart 8.4 ms — **5.24×**. The user's instinct ("dart is
excellent at floating point unboxing, there is something wrong") was right:
the optimized IR showed the arithmetic *perfectly* unboxed (loop phis
`alive double`, `BinaryDoubleOp` throughout, `zr*zr` pattern-matched to
`MathUnary('double-square')`). All the loss was in the comparisons.

## The mechanism

`kHelperRewrites` funnelled `<` `<=` `>` `>=` through four tiny dart:cocoa
helpers (`stLess` …). Each helper is small on purpose so the inliner always
splices it — but every inlined copy carries the **helper's own ICData**, which
aggregates every receiver pair in the image. On arm64 `SmiFitsInDouble()` is
false (62-bit Smis don't fit a 53-bit mantissa), so one Smi pair plus one
Double pair is already unspecializable: `TryReplaceWithRelationalOp` bails and
the compare degrades to `Box(double)` + `StaticCall` + `StrictCompare` per
iteration. Boxing a Smi is free; boxing a Double is a heap allocation — hence
double-heavy code paid worst.

Because the ICData is image-global, the damage is **order-dependent**: the
first method to optimize claims the funnel while it is monomorphic and stays
fast forever; every later method inherits the merged feedback. Measured
(minimal repro, fresh VM each):

    B1 dcmp: (before any Smi cmp)   10.25 ms   <- parity with Dart
    BS icmp: (Smi, unrelated class) 25.04 ms   <- poisoned by B1's Double pair
    B2 dcmp: (after the Smi cmp)   142.10 ms   <- 14x, poisoned by BS's Smi pair
    B1 dcmp: (re-timed at the end)  10.27 ms   <- got in first, fast forever

Same failure the `add:` and value-family comments in
`st_flow_graph_builder.cc` already record; the relational four were the last
funnel survivors. Corroboration: `to:do:` emits its bound check as a direct
per-site `InstanceCall(<=)` — the one comparison that skipped the funnel was
the one comparison at parity.

## The fix (three parts, no per-site guards)

1. **Builder** — the four entries are removed from `kHelperRewrites`; the
   generic send tail already maps them via `MethodKind` to real Token kinds,
   so every site gets its own ICData and fuses to `Branch if RelationalOp`.

2. **Runtime lib** — plain removal alone broke `0 < (3/4)`:
   `_IntegerImplementation.<` is `return other > this`, and `Fraction>>>` is
   `^aNumber < self` — two reversals, an infinite 2-cycle (the double-receiver
   variant `0.6 < (3/4)` cycled too, previously untested). The funnel's rare
   tail existed to break exactly this. Fixed at the root instead:
   `integers.dart`/`double.dart` `<` `<=` `>=` route a **non-num argument**
   through the coercion privates (`_greaterThanFromInteger`,
   `_equalToInteger`) that the stObjNSM hook in `cocoa.dart` *already*
   translates to forward ST sends — the same route `operator>` and mixed
   arithmetic have always taken. These branches are dead in optimized code (a
   specialized site is a `RelationalOp` and never calls the body), so the fast
   path pays nothing. This also fixed a latent wrong-answer plain removal
   would have shipped: `0.5 <= (1/2)` was false (num `==` rejects any ST
   operand); it now answers true via `_equalToInteger`.

3. **Fingerprints** — the six operators are VM-recognized intrinsics;
   `method_recognizer.h` carries their updated source fingerprints
   (`<` 0x6896fd05, `<=` 0x76831143, `>=` 0x2df1a8e3 — int and double share
   per selector because the bodies are token-identical).

All three land in the tree via `st-tree.patch` (verified: patch applies to
pristine sdk copies and reproduces the live tree byte-for-byte).

## Rejected on measurement

A per-site class-id **guard** on the argument (mirroring the value-family
lowering) was built and measured first: correct, and mandel hit 1.01x, but
the un-hoistable `LoadClassId` per iteration cost Smi-heavy code 2.4–3.9x
and cog-bench regressed (fib 2×, deltablue +29%). Guarding at every site to
protect two rare shapes was the wrong trade; the runtime-lib fallback costs
those shapes alone.

## After (arm64, Oryon; `test/st_vs_dart.dart`, warmed, best-of-5)

    workload      ST(ms)   Dart(ms)   ratio        baseline
    loopCmp         3.42       3.39    1.01x        1.01x
    sumDbl         10.30      10.25    1.00x        1.00x
    nestIf          3.43       3.39    1.01x        1.01x
    andOr           6.95       6.90    1.01x        (broken row)
    toDo            6.86       6.84    1.00x        1.01x
    dblCmp         10.44      10.42    1.00x       12.30x
    boundIvar       3.44       3.39    1.01x        7.44x
    escLocal       23.01      22.49    1.02x        4.64x
    escIvar        23.06      22.98    1.00x        3.65x
    mandel          8.61       8.38    1.03x        5.10x
    ------------------------------------------------------
    mean 1.01x, worst 1.03x              (baseline mean 3.75x)

MandelZoom's frame compute: **37.1 ms → 8.6 ms** (4.3×); the ~22 fps cap is
gone. Cog-bench ×3: fib 165–167 (baseline 169.6), alloc ~114 (113.2),
deltablue 26–28 (25.9), richards ~11 (10.8) — no regression. Correctness:
30/30 relational cases including Strings, Symbols, Characters,
SortedCollection, both Fraction 2-cycles, and the equal-value mixed cases;
`st_world_run` functional pass green.

## Notes

- `boundIvar`'s 7.44x was the same funnel bug, not a separate ivar problem —
  it vanished with the fix.
- The x64 build shares every file touched (nothing arch-specific — arm64 just
  hurt more because `SmiFitsInDouble` is false there and its funnel IC went
  polymorphic faster); rebuild x64 before using it as a control again.
- Repro/IR: `dart.exe --print-flow-graph-optimized
  --print-flow-graph-filter=escapeAtRe_im_ test/st_vs_dart.dart st/world`.
