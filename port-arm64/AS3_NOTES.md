# AS3 — dart:io, isolates, and the hot-reload/i-cache probe (notes)

Sprint AS3 of `SPRINTS_ARM64.md`. **Exit met 2026-08-12**, plus one genuine
arm64-specific VM bug found, isolated, and worked around (§3).

## 1. The i-cache verdict — clean

`test\reload_churn.dart` (new): 500 rounds, each round rewrites an imported
library, calls `Dart_WorkspaceReloadSources`, hammers the reloaded function 400×
to force optimising recompilation, then asserts both the constant and the
computed result.

```
CHURN: 500 rounds x 400 calls
CHURN: 90897 ms  (181.8 ms/round)
CHURN: reloadErrors=0 staleValue=0 staleHot=0
CHURN_OK
```

**200,000 calls into 500 freshly-compiled-and-patched code objects, zero stale
reads.** The test has teeth: a no-op reload fails round 1 (it would read the
previous round's constant), and a missing i-cache flush is exactly a stale-read
failure. Plan risk 1 — the non-coherent i-cache — is now **exercised, not
argued**. `windart-arm64.patch`'s `FlushInstructionCache` hunk does its job.

## 2. The longjmp/SEH verdict — clean, no change needed

`test\syntax_recover.dart` (new): 8 checks through `wsCheckSyntax` — a valid
class, a leading UTF-8 BOM, four hard syntax errors, an unresolved import, then
a valid class again plus arithmetic to prove the isolate is still healthy.

```
SEH: 8 checks, 0 failures
SEH_OK
```

Every error is **reported catchably; the VM never aborts**. Plan risk 6
confirmed: the `_MSC_VER` gate in `longjump.cc` (skip `StackResource::
UnwindAbove`, let SEH unwind) remains correct on arm64 — **no arm64 change**.
Independently confirmed with a standalone probe: MSVC's `longjmp` **does** run
C++ destructors on arm64, same as x64.

> **RESOLVED in AS7 (see `AS7_NOTES.md` §2) — and the diagnosis below is wrong.**
> It is not arm64-specific and has nothing to do with the dual stack pointer.
> The port was inheriting CMake's default `/EHsc`, so `longjmp` performed an SEH
> unwind that ran C++ destructors — a second unwinder competing with Dart's own
> `StackResource::UnwindAbove`. Compiling exceptions-off (upstream Dart's own
> posture) and restoring the unconditional manual unwind fixes it on both
> architectures. The evidence gathered below is sound; the conclusion drawn
> from it was not. Kept as written, because how it looked from inside is the
> useful part.

## 3. BUG (arm64-specific): `allocation.cc` StackResource assert under
##    background compilation + aggressive optimisation + hot-reload

### Repro
```
build-arm64\dart.exe --optimization_counter_threshold=100 \
    test\reload_churn.dart 12 400
-> tree\runtime\vm\allocation.cc: 37: error: expected: top == this   (exit 3)
```
Deterministic: **always round 7**, across every run.

### It is arm64-specific — controlled
Same tree, same test, both binaries built from it on this machine (x64 via the
`vcvarsarm64_amd64` cross tools, run under WoA x64 emulation):

| arch | `--optimization_counter_threshold` | result |
|---|---|---|
| arm64 | default (30000) | `CHURN_OK` |
| arm64 | **100** | **assert, round 7** |
| x64 | default (30000) | `CHURN_OK` |
| x64 | **100** | `CHURN_OK` |

### Conditions (each necessary)
- **background compilation** — `--no_background_compilation` makes it pass.
- **aggressive optimisation** — default threshold passes; 100 fails.
- **genuinely changed libraries across reload** — `test\reload_min.dart`
  (20 reloads, no source change) passes cleanly.

### What was ruled OUT
- **i-cache / codegen.** Failure round is identical at hammer = 0, 50, 400 and
  4000, and is deterministic; an i-cache fault would be neither.
- **longjmp not unwinding.** Standalone probe: arm64 `longjmp` *does* run
  destructors. Forcing the manual `UnwindAbove` on arm64 made things strictly
  worse — `syntax_recover` then aborted with the same assert (double-destruct),
  while the churn still failed. **Neither blanket setting is correct**: SEH
  unwinds in the syntax-error path but evidently not in the compile path.
- **`COPY_FP_REGISTER` (patch hunk #2).** Used only by `Profiler::DumpStackTrace`,
  not by the StackResource chain. (It does explain the useless 2-frame crash
  dumps — see §4.)

### Evidence
Instrumenting `~StackResource` to name the stranded resources (`typeid` on the
live `top`, which is valid; `this` is already partly destroyed in a base dtor):

```
stranded[0..3]  TimerScope / TimelineDurationScope (x2 pairs)
stranded[4]     CHA
stranded[5]     LongJumpScope
stranded[6]     HandleScope
stranded[7]     TimerScope
stranded[8]     StackZone
stranded[9]     LongJumpScope
stranded[10..13] TimelineDurationScope / VMTagScope / HandleScope / StackZone
LIFO break: this=...B4B8 top=...C8A0 depth=14 reached_this=0
```

That is precisely the **compiler's** scope stack, left linked. Correlating with
a print inside `LongJump::Jump` (all on the **mutator** thread, tid 13068):

```
LongJump::Jump  top_res=...B9D8  target_top_=...B4B8    <- INVERTED
LongJump::Jump  top_res=...C8A0  target_top_=...C3D0
LIFO break:     this=...B4B8     top=...C8A0  reached_this=0
```

A healthy jump has `target_top_` at a **higher** (older/shallower) address than
the current top — the startup jump does (`C1E0` → `C3D0`). The round-7 jump is
**inverted**: its saved `top_` (`B4B8`) is *deeper* than the live top (`B9D8`),
so `UnwindAbove`/the unwind can never reach its target and 14 resources are
stranded. `this` in the final break is that same `B4B8`.

### Working hypothesis (not yet proven)
Non-monotonic C++ StackResource addresses caused by arm64 Dart's **dual stack
pointer**. `Assembler::EnterFrame` parks the hardware `CSP` at
`(SP − 4096) & ~15`, so the C++ frame for a runtime entry begins 4 KB below the
*Dart* SP at that moment. Two runtime entries made at different Dart stack
depths therefore produce C++ StackResources whose addresses are **not ordered by
C++ nesting** — which is exactly the assumption the address-ordered unwind
relies on. Background compilation + a low optimisation threshold multiplies the
number of interleaved compile-time runtime entries, which is why those two flags
are necessary to expose it. x64 has a single SP and cannot produce the inversion.

Proving this needs a debugger (`cdb`/WinDbg are **not** installed on this box —
`Windows Kits\10\Debuggers\arm64` exists but is empty) and is its own piece of
work, deferred to AS7.

### Workaround (in effect now)
Default flags are unaffected — the shipping configuration never sets a low
optimisation threshold. Where aggressive optimisation *is* wanted alongside
hot-reload, add `--no_background_compilation`. Verified:

```
dart.exe --optimization_counter_threshold=100 --no_background_compilation \
    test\reload_churn.dart 300 400      ->  CHURN_OK  (0 errors, 0 stale)
```

## 4. Side finding: crash dumps are 2 frames deep

`Profiler::DumpStackTrace` prints only itself, twice. Patch hunk #2 routes
arm64's `COPY_FP_REGISTER` to `Thread::GetCurrentStackPointer()` (the x64
fallback), so the profiler walks from an *SP* value where it expects an *FP* —
the walk terminates immediately. Harmless to execution, but it removes native
stack traces exactly when they are most wanted. A real fix would read x29;
MSVC arm64 has no inline asm, so it needs either an `armasm64` helper or
`_ReadStatusReg`-style intrinsics. Filed for AS7 alongside the profiler work
(hunk #6's `dsp = X[15]` is validated there too).

## 5. Regression set (all green, clean tree, default flags)

| test | result |
|---|---|
| `hello.dart` | `hello, windart` |
| `test\io_test.dart` | `IO_TEST_OK` |
| `test\isolate_test.dart` | `ISOLATE_TEST_OK` |
| `test\mirror_test.dart` | 337 classes |
| `test\syntax_recover.dart` | `SEH_OK` |
| `test\reload_min.dart` | `MIN_OK` |
| `test\reload_churn.dart 500` | `CHURN_OK` |

The tree was regenerated from pristine via `extract.py` before this run, so all
three patches round-trip and the triage instrumentation is gone.
