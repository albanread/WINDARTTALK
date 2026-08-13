# Blog drafts — the Snapdragon port series

Draft articles from the WINDARTARM project: porting WINDARTTALK (a Dart
1.24.3 JIT VM carrying a live Smalltalk world and IDE) to Windows-on-ARM64,
developed *on* the target — a Snapdragon X laptop whose Oryon cores run the
build, the tests, and the finished product.

1. [A 2017 JIT meets a 2026 laptop](01-a-2017-jit-meets-a-2026-laptop.md) —
   the bring-up: MSVC's `_M_ARM64`, the silent-interpreter trap, the
   instruction cache that does not forgive, and why the whole port fit in
   8 files and 20 hunks.
2. [Unified memory is real — we measured it](02-unified-memory-is-real.md) —
   what the Adreno X1-45's shared memory actually buys: 8× uploads for one
   flag change, free readback, and a negative result worth publishing.
3. [The case of the slow Mandelbrot](03-the-case-of-the-slow-mandelbrot.md) —
   a JIT performance mystery: five wrong hypotheses, an order-dependent
   repro, and the day our Smalltalk hit 1.01× of hand-written Dart.
4. [Racing the emulator](04-racing-the-emulator.md) — native arm64 vs the
   same VM's x64 build under Prism, and the humbling row where the
   emulator won.
5. [A Smalltalk world, byte-identical, on a Snapdragon](05-a-smalltalk-world-on-a-snapdragon.md)
   — 97 Mac-authored source files boot unmodified; Metal shaders run on
   D3D11; the whole IDE is scriptable from TCL.

All numbers were measured on the machine the articles describe: Snapdragon X
(Oryon, 8 cores), Windows 11 arm64, Adreno X1-45. Deeper technical notes
live in `../port-arm64/`.
