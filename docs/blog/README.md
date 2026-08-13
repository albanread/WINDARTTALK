# The Snapdragon series

Field notes from porting WINDARTTALK — the **Dart 1.24.3 JIT VM** carrying a
live **Smalltalk** world and IDE — to **Windows-on-ARM64**, developed *on*
the target: a Snapdragon X laptop whose Oryon cores run the build, the
tests, and the finished product.

A note on method: I steer, and **Claude** (Anthropic's coding agent) does
the digging — writing the probes, running the builds, dumping the IR, and
holding theories until the measurements disagree, which they did rather
often. Article 3 in particular began with me telling Claude its favourite
hypothesis was wrong. It was.

1. [A 2017 JIT meets a 2026 laptop](01-a-2017-jit-meets-a-2026-laptop.md) —
   the bring-up: MSVC's `_M_ARM64`, the silent-interpreter trap, and the
   instruction cache that does not forgive. **8 files, 20 hunks**, in the end.
2. [Unified memory is real — we measured it](02-unified-memory-is-real.md) —
   what the Adreno X1-45 actually buys: **8×** uploads for one flag change,
   readback at heap speed, and one negative result.
3. [The case of the slow Mandelbrot](03-the-case-of-the-slow-mandelbrot.md)
   — five wrong hypotheses, an order-dependent repro, and Smalltalk ending
   up at **1.01×** of hand-written Dart, which will do.
4. [Racing the emulator](04-racing-the-emulator.md) — native arm64 against
   the same VM under Prism, including the rows where the emulator wins.
5. [A Smalltalk world, byte-identical, on a Snapdragon](05-a-smalltalk-world-on-a-snapdragon.md)
   — 97 Mac-authored files boot unmodified; Metal shaders on D3D11; an IDE
   you drive from TCL.

Every number was measured on the machine described: Snapdragon X (Oryon,
8 cores), Windows 11 arm64, Adreno X1-45. The full engineering log lives in
[`../../port-arm64/`](../../port-arm64/).
