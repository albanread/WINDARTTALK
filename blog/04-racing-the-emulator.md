# Racing the emulator

*Native arm64 vs the same VM's x64 build under Prism — same source, same
machine, and one humbling result.*

Ports usually can't benchmark themselves against a counterfactual. Ours
can. The build system produces two binaries from one tree: `dart.exe` for
arm64 (our port, running natively on the Snapdragon's Oryon cores) and
`dart.exe` for x64 (the original, battle-tested backend), which Windows 11
runs through **Prism**, its x86-to-ARM translation layer. Same VM source,
same commit, same benchmarks, same silicon. The only variables: which code
generator, and whether a translator sits underneath.

That makes this a clean two-question experiment. How good is Prism? And —
less comfortably — how good is *our* side of the fence?

One methodological note: the previous article matters here. Both binaries
now hold Smalltalk at 1.01× of Dart internally, so every cross-binary ratio
below is pure backend-plus-translation, with no front-end skew. All runs
warmed, best-of-N, translation cache hot.

## The numbers

    emulated / native  (>1 = native wins)

    boot + parse/compile a 97-file image     1.34x     (branchy C++)
    tight integer compare-branch loops       1.50-1.54x
    dictionary / scheduler / classic OO      1.26-1.38x
    allocation churn                         1.09x
    recursive call-heavy (fib)               0.98x     (emulator ties)
    double arithmetic loops                  0.98-1.00x (emulator ties)
    Mandelbrot escape loops                  0.88-0.92x (EMULATOR WINS)

    geometric mean: ~1.26x on the classic suite, ~1.16x on microbenchmarks

## Reading the clusters

**Prism's tax lands on throughput-bound integer code.** The 1.5× rows are
tight compare-and-branch loops running at ~1.2 cycles per iteration
natively. That code is nothing *but* x86 flag traffic — compare, branch on
flags, increment, repeat — and flag semantics are where x86-to-ARM
translation has to work hardest. Every extra translated micro-op is visible
when the loop has no slack.

**The tax vanishes on latency-bound floating point.** The double loops
chain each iteration on the previous one's `fadd` result (~1 ns per
iteration of unavoidable dependency latency). Translation overhead hides
entirely inside that shadow: the core is waiting anyway. Result: parity,
to the percent.

**Statically-compiled C++ pays about 1.34×** — parsing, compiling, GC. For
a translator, that is a remarkable number; a decade ago the folk estimate
for emulating x86 was "several times slower."

And a correctness note that deserves more amazement than it will get: our
x64 binary is a *JIT*. It writes freshly generated x86 machine code into
writable-executable pages at runtime, patches it, throws it away, writes
more. Prism translated all of it, continuously, without one wrong answer
across the entire test battery. Dynamic code translation of a foreign JIT
is the hard case, and it just... worked.

## The humbling row

Look again at the escape loops: **0.88×**. The x64 binary — running through
an emulator — beats our native arm64 build by 12% on the exact workload
this whole project showcases.

Sit with the logic of that. Prism cannot execute x64 code at *better* than
native efficiency; translation only subtracts. So if translated-x64 wins,
the input to the translator — the mature x64 backend's generated code —
must be sufficiently better than our arm64 backend's output to pay Prism's
toll and still finish first. What we are really racing is two code
generators: Google's x64 backend (years of tuning on desktop x86, by the
lineage of team that built V8) plus Microsoft's translator, versus Dart
1.24's arm64 backend, which was written for Cortex-A53-era phone cores and
had never met a wide out-of-order machine like Oryon.

The call-heavy `fib` tying at 0.98× points at one concrete suspect: our
arm64 frame entry maintains *two* stack pointers (an architectural
requirement discussed in the first article), and that bookkeeping is
per-call overhead the x64 backend simply doesn't have. The FP loops
suggest the arm64 backend's instruction selection leaves a little on the
table besides. Neither is confirmed yet; both are now measurable.

## The doctrine we took away

We now treat the emulated binary as **the performance floor**. It is the
best available evidence of what this silicon can do for this VM — produced
by a better-tuned code generator, handicapped by a translator. Any
workload where the emulated build beats the native one is, by
construction, native-backend headroom. Current list: the escape loops
(0.88–0.92), and `fib` (0.98). That list is the tuning roadmap, and
re-running one script tells us when it is empty.

For users, the practical summary is friendlier: native wins where software
*feels* — 34% faster boot-and-compile, 25–50% faster on general
object-oriented workloads — and the FP-heavy demo code sits within 12% of
the best code generation known for this chip. That last 12% is ours to go
and get.

*Next: the payload all this infrastructure carries — a 97-file Smalltalk
world, written on a Mac, booting byte-identical on a Snapdragon.*
