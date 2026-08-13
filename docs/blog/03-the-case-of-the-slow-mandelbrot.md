# The case of the slow Mandelbrot

*Five wrong hypotheses, an order-dependent repro, and Smalltalk ending up
at 1.01× of hand-written Dart. A story about measuring instead of
theorizing — and about telling your AI it's wrong.*

The bug report was mine, and brief: *"the mandel zoom seems slow."*
`MandelZoom` is the showcase demo — a Smalltalk class computing escape-time
fractals into a shared-memory framebuffer, 320×240 at up to 150
iterations a pixel, roughly 11.5 million inner-loop iterations per frame.
It was managing about 22 fps on a machine with no business being that
slow.

What follows is the investigation as it actually ran, wrong turns
included, because the wrong turns carry most of the lessons. The division
of labour: Claude did the measuring and held the theories; I supplied the
scepticism.

## Hypothesis 1: boxed doubles. Wrong.

Smalltalk on a Dart VM sounds like a recipe for heap-allocated arithmetic,
so that was Claude's opening theory. I didn't believe it — *"dart is
excellent at floating point unboxing, there is something wrong"* — and the
benchmark suite agreed in one run: the `arith` workload, straight-line
float maths through the Smalltalk front-end, ran 11.7 ms — fourteen times
faster than the send-heavy `fib`. If doubles were boxing, `arith` would be
an allocation benchmark. It wasn't.

## Hypothesis 2: the GPU path. Wrong.

We had just rebuilt the upload path around unified memory (previous
article), so suspicion fell there next. Measurement: compute a full frame
with the two GPU calls deleted. **44.3 ms of pure CPU compute** — against
**8.4 ms** for byte-identical maths written in plain Dart, same process,
same VM. A 5.24× gap with no GPU in sight.

## Hypothesis 3: the optimizer isn't running. Wrong — and usefully so.

Claude dumped the optimized IR for the hot method. The arithmetic was
beyond reproach: the four loop-carried variables lived in FP registers
across the back-edge (`phi … alive double`), every operation was an
unboxed `BinaryDoubleOp`, and the optimizer had even pattern-matched
`zr*zr` into a dedicated square operation. So much for hypothesis one,
again.

The tell sat two lines down. The loop's *comparisons* — `zr2 + zi2 < 4.0`
— compiled to: **box the double** (a heap allocation per iteration),
**call** `<` as a function, then compare the returned bool with `true`.
The maths travelled in registers; the comparisons went by post.

## Hypothesis 4: our condition lowering. Wrong.

Theory: the Smalltalk front-end materializes conditions as bool values and
defeats compare-and-branch fusion. To test it, Claude built the instrument
that should have existed from day one — **paired microbenchmarks**, each
workload written twice with identical semantics, Smalltalk and Dart:

| workload | ST/Dart |
|---|---|
| int compare loop | 1.01× |
| if/else in a loop | 1.01× |
| counted loop | 1.01× |
| **double compare loop** | **12.30×** |
| **loop bound in an instance variable** | **7.44×** |

A pure integer comparison loop at parity killed the lowering theory. Only
*double* comparisons were disastrous — and the IR held one more oddity:
the double compare site carried inline-cache entries for integer *and*
double, including an integer entry with a hit count of **zero**. Type
feedback from comparisons this code had never performed was somehow
poisoning it.

## The experiment that settled it

If the pollution comes from elsewhere, the same code in isolation should
be fast. It was:

    identical double-compare method, alone:     10.19 ms   (Dart parity)
    same method, in the full test suite:       126.95 ms

Then the minimal repro — four lines that explain everything:

    B1 double-loop  (run first)          10.25 ms   fine
    BS int-loop     (unrelated class)    25.04 ms   should be 3.4
    B2 double-loop  (identical to B1)   142.10 ms   14×
    B1 again                             10.27 ms   still fine

Performance was **order-dependent**. Whichever method the JIT optimized
first ran at full speed indefinitely; everything compiled afterwards was
quietly degraded. In a 97-file Smalltalk image, "afterwards" is nearly
everything.

## The cause: a helper that was tiny on purpose

The front-end routed the comparison operators through four small Dart
helpers — `stLess` and friends — deliberately tiny so the inliner would
always splice them into hot code. It did. But an inlined call site carries
the *helper's* type-feedback record, and there is exactly one `stLess` in
the image, so its record aggregates **every comparison of every type
anywhere**. Once it held both integer and double pairs, no site could
specialize — on arm64 the two cannot share an inline cache (a 62-bit
tagged integer does not fit a 53-bit mantissa) — and every comparison in
the image decayed to allocate, box, call.

The part I enjoyed least: the source file already *documented this exact
failure* for two earlier helpers, in comments, with measurements. The
comparison operators were simply the last survivors of the pattern. And
the one comparison the front-end had always emitted per-site rather than
through a helper — the counted-loop bound check — was the one comparison
benchmarking at parity all along. The evidence had been sitting there
being ignored, by machine and human alike.

## The fix that wasn't, then the one that was

Attempt one: keep the helpers for exotic operands and guard each site with
a class-id check. Correct, and no good: the guard cost integer-heavy code
2.4–3.9× and doubled `fib`. Rejected on measurement, which is the only
respectable way to reject a design.

The observation that unlocked the proper fix: **in optimized code, a
specialized comparison never executes the operator's method body at all** —
the JIT fuses it into a compare-and-branch. The body runs only in cold and
rare paths. So the one correctness case the helpers genuinely protected
(Smalltalk's `0 < (3/4)`, where Dart's integer `<` and the Smalltalk
Fraction each politely reverse the operands toward the other, indefinitely)
could be handled *inside the runtime library's operator body* — dead code
in every hot loop — by routing non-numeric arguments through coercion
hooks the Smalltalk bridge already had. Comparisons compile as plain
per-site operations everywhere; the reversal cycle is broken at its root;
no guard anywhere.

## The scoreboard

    ST vs Dart, before:   mean 3.75×, worst 12.30×
    ST vs Dart, after:    mean 1.01×, worst 1.03×
    MandelZoom frame:     37.1 ms → 8.6 ms
    Cog-bench suite:      flat — nothing regressed
    Correctness:          30/30, both reversal cycles included

A dynamically-dispatched Smalltalk, compiled through a Dart VM's JIT,
running double-heavy numeric code within 3% of hand-written Dart. We'll
take it.

## What we keep

1. **Measure before theorizing.** Five hypotheses died on contact with
   data. The paired benchmark took an hour to write and found in minutes
   what speculation had circled for days.
2. **Push back on your tools.** "Dart is excellent at unboxing" was the
   correct prior. Claude's job was to be wrong efficiently; mine was to
   say so early.
3. **Shared caches make performance non-local.** The unsettling property
   of this bug: running one benchmark changed the compiled speed of
   unrelated code. If a language funnels a hot operation through one
   shared helper, that helper's type feedback becomes a global variable.
4. **Write failures down where the next person trips.** The codebase
   warned about this pattern twice. The third instance survived anyway —
   but those comments are why recognizing it took minutes once the IR
   pointed there, rather than another round of theorizing.

*Next: with both builds finally honest, we race the native arm64 VM
against its own x64 binary under Microsoft's emulator. The emulator takes
a round.*
