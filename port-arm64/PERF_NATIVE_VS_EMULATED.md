# Native arm64 vs x64-under-Prism — same VM, same tree, same machine

A clean experiment the port makes possible: `build-arm64\dart.exe` (Dart
1.24's arm64 backend, native on Oryon) against `build-x64\dart.exe` (the
mature x64 backend, under Windows-on-ARM Prism emulation), built from the
same tree at the same commit (12490ae, both Debug config), measured
back-to-back on the same Snapdragon X. Because the relational-funnel fix
holds ST at 1.01x of Dart inside BOTH binaries (see PERF_ST_VS_DART.md),
every ratio below is backend codegen + translation, with no ST skew.

Driver: scratchpad `native_vs_emu.ps1` — boot ×3, st_vs_dart (internally
warmed best-of-5), cog-bench best-of-2. The Prism translation cache was warm
(both binaries had run before measurement).

## Results (emu/native; >1 = native wins)

    boot + parse/compile 97 .mst (C++ VM)   3.46 s vs 4.64 s     1.34x

    st_vs_dart (Dart column = pure backend, no ST)
      loopCmp   1.53x      toDo     1.38x      dblCmp   0.98x
      nestIf    1.50x      andOr    1.26x      sumDbl   1.00x
      boundIvar 1.53x                          escLocal 0.92x
                                               escIvar  0.91x
                                               mandel   0.88x
    cog-bench
      arith 1.52x   dict 1.38x   richards 1.36x   sieve 1.29x
      deltablue 1.26x   alloc 1.09x   fib 0.98x

    geomean: ~1.26x (cog-bench), ~1.16x (Dart micro-suite)

## Reading the two clusters

**Throughput-bound integer code pays 1.25–1.54x.** The worst rows are tight
compare-and-branch loops (~1.2 cycles/iteration native) — flag-dense x86
where every extra translated µop is visible. Classic worst case for an
x86→ARM translator.

**Latency-bound FP code pays nothing.** sumDbl/dblCmp chain on fadd latency
(~1 ns/iteration); translation overhead hides entirely in the dependency
shadow. Parity.

**Prism itself is excellent.** 1.34x on branchy statically-compiled C++, and
flawless correctness while the x64 binary JIT-writes fresh x86 code into RWX
pages at runtime — dynamic code re-translation never missed (30/30
relational cases, full world functional pass, identical benchmark answers).

## The finding that matters for the port

On mandel and the escape loops, **translated x64 beats our native backend by
8–12%** (and fib reaches parity). Prism cannot exceed 100% efficiency, so
"mature x64 backend + Microsoft's translator" is producing better arm64 code
than Dart 1.24's own arm64 backend — which was tuned for Cortex-A53-era
in-order mobile cores, not a wide out-of-order Oryon. Candidate causes,
untested:

- `EnterFrame`'s dual-stack maintenance (`CSP = (SP-4096) & ~15`) is
  per-call overhead the x64 backend has no analogue of — consistent with
  call-heavy fib at 0.98x while loop-heavy rows win 1.5x.
- FP codegen patterns (register moves, compare sequences) in the 1.24 arm64
  backend predate modern wide cores.

**Use the emulated binary as the floor**: any workload where
`build-x64\dart.exe` under Prism beats `build-arm64\dart.exe` native marks
arm64-backend headroom. Current list: mandel (0.88), escIvar (0.91),
escLocal (0.92), fib (0.98). AS7-adjacent tuning targets.

## Practical bottom line

Native wins where the feel is: boot/compile 34% faster, general Smalltalk
workloads 25–50% faster. FP-heavy game code is within 12% of the best
available codegen for this chip — and that gap is ours to close, not
emulation magic to envy.
