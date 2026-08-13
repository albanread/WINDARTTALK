# The case of the slow Mandelbrot

*A JIT performance mystery in five wrong hypotheses — and the day our
Smalltalk hit 1.01× of hand-written Dart.*

The bug report was four words: "the mandel zoom seems slow." MandelZoom is
our showcase demo — a Smalltalk class computing escape-time fractals into a
shared-memory framebuffer, 320×240 at 150 iterations max, about 11.5
million inner-loop iterations per frame. It was crawling at ~22 fps on a
machine that should eat it.

What follows is the investigation as it actually happened, wrong turns
included, because the wrong turns are the useful part.

## Hypothesis 1: boxed doubles. Wrong.

Smalltalk-on-a-Dart-VM sounds like a recipe for heap-allocated arithmetic,
so that was the reflexive first theory. The project's benchmark suite
killed it in one run: the `arith` benchmark — straight-line float math
through the Smalltalk front-end — ran 11.7 ms, *fourteen times faster*
than the send-heavy `fib`. If doubles were boxing, `arith` would be an
allocation benchmark. The owner's pushback was blunt and correct: "dart is
excellent at floating point unboxing, there is something wrong."

## Hypothesis 2: the GPU path. Wrong.

We had just rebuilt the upload path around unified memory (see the previous
article), so suspicion naturally fell there. Measurement: compute a full
frame with the two GPU calls deleted. 44.3 ms of *pure CPU compute* —
against 8.4 ms for byte-identical maths written in plain Dart, in the same
process, on the same VM. A 5.24× gap with no GPU in sight. The GPU was
exonerated; the deficit was in the compiled code.

## Hypothesis 3: the optimizer isn't running. Wrong — and beautifully so.

We dumped the optimized IR for the hot method. The arithmetic was
*perfect*: the four loop-carried variables lived in FP registers across
the back-edge (`phi ... alive double`), every operation was an unboxed
`BinaryDoubleOp`, and the optimizer had even pattern-matched `zr*zr` into
a dedicated square instruction. Whatever was slow, it was not the floats.

The tell was two lines further down. The loop's *comparisons* — `zr2 + zi2
< 4.0` — compiled to: box the double (a heap allocation per iteration),
call `<` as a function, then compare the returned bool to `true`. The maths
was flying first-class while the comparisons rode in the cargo hold.

## Hypothesis 4: our condition lowering. Wrong.

Theory: the Smalltalk front-end materializes conditions as bool values,
defeating compare-and-branch fusion. We built the instrument that should
have existed from day one — a suite of *paired* microbenchmarks, each
workload written twice with identical semantics, once in Smalltalk and
once in Dart:

    loopCmp  (int compare loop)      1.01x
    nestIf   (if/else in a loop)     1.01x
    toDo     (counted loop)          1.01x
    dblCmp   (DOUBLE compare loop)  12.30x   <--
    boundIvar (bound in an ivar)     7.44x   <--

A pure integer comparison loop was at parity — so condition lowering was
fine. Only *double* comparisons were catastrophic. And here the IR
delivered a genuinely weird clue: the double compare site had inline-cache
entries for `Smi` (integer) *and* `Double` — including a Smi entry with a
hit count of **zero**. Type feedback from integers this code had never
compared was poisoning a loop about doubles.

## The experiment that cracked it

If the pollution comes from elsewhere, the same code run in isolation
should be fast. It was — embarrassingly so:

    identical double-compare method, alone:      10.19 ms   (Dart parity)
    same method, in the full test suite:        126.95 ms   (12x)

Then the minimal repro, four lines that explain everything:

    B1 double-loop  (run first)          10.25 ms   fast
    BS int-loop     (unrelated class)    25.04 ms   should be 3.4
    B2 double-loop  (identical to B1)   142.10 ms   14x
    B1 again                             10.27 ms   still fast

Performance was **order-dependent**. Whichever method the JIT optimized
first ran at full speed forever; everything compiled after it was
permanently degraded. In a 97-file Smalltalk image, "after it" is nearly
everything.

## The cause: a helper that was tiny on purpose

The Smalltalk front-end routed the comparison operators through four small
Dart helpers — `stLess` and friends — deliberately tiny so the inliner
would always splice them into hot code. It did. But an inlined call site
carries the *helper's* type-feedback record, and there is exactly one
`stLess` in the image, so its record aggregates **every comparison of
every type anywhere**. Once it holds both integer and double pairs, no
site can specialize (on arm64 the two cannot share an inline cache — a
62-bit tagged integer does not fit a 53-bit mantissa), and every compare
in the image decays to allocate-box-call.

The delicious detail: the source file already *documented this exact
failure* for two earlier helpers, with measurements, in comments. The
comparison operators were the last survivors of the pattern. And the one
comparison the front-end emitted per-site rather than through a helper —
the counted-loop bound check — was the one comparison benchmarking at
parity all along.

## The fix that wasn't, then the fix that was

Attempt one: keep the helpers for exotic operands, guard each site with a
class-id check. Correct — and a disaster on the benchmarks: the guard cost
integer-heavy code 2.4–3.9× and doubled `fib`. Rejected on measurement,
which is the only honest way to reject a design.

The insight that unlocked the real fix: **in optimized code, a specialized
comparison never executes the operator's method body at all** — the JIT
fuses it into a compare-and-branch. The body only runs in cold and rare
paths. So the one correctness case the helpers truly protected (Smalltalk
`0 < (3/4)`, where Dart's integer `<` and the Smalltalk Fraction each
politely reverse the operands at the other, forever) could be fixed *inside
the runtime library's operator body* — dead code in every hot loop — by
routing non-numeric arguments through the coercion hooks the VM's Smalltalk
bridge already had. Comparisons compile as plain per-site operations
everywhere; the 2-cycle is broken at its root; no guard anywhere.

## The scoreboard

    ST vs Dart, before:  mean 3.75x, worst 12.30x
    ST vs Dart, after:   mean 1.01x, worst 1.03x
    MandelZoom frame:    37.1 ms -> 8.6 ms  (4.3x)
    Cog-bench suite:     flat -- nothing regressed
    Correctness:         30/30, including both reversal cycles

A dynamically-dispatched Smalltalk, compiled through a Dart VM's JIT,
running double-heavy numeric code within 3% of hand-written Dart.

## What we keep

1. **Measure before theorizing.** Five hypotheses died on contact with
   data. The paired ST/Dart benchmark took an hour to write and found in
   minutes what speculation missed for days.
2. **Listen to the domain expert's instinct.** "Dart is excellent at
   unboxing" was the correct prior; the evidence eventually agreed.
3. **Shared caches make performance non-local.** The scariest property of
   this bug: running one benchmark changed the compiled speed of unrelated
   code. If your language funnels a hot operation through one shared
   helper, its type-feedback becomes a global variable.
4. **Write the failure down where the next person will trip.** The codebase
   warned about this pattern twice, with measurements, in comments. The
   third instance survived anyway — but those comments are why recognizing
   it took minutes once the IR pointed there, instead of another round of
   theorizing.

*Next: with both builds finally honest, we race the native arm64 VM against
its own x64 binary under Microsoft's emulator. The emulator wins a round.*
