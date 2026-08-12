# WINDARTARM — Windows **arm64** (Snapdragon) Porting Plan

**Goal:** a native **Windows-on-ARM64 JIT** build of the Dart **V1** VM (1.24.3)
and its live IDE, on Qualcomm Snapdragon (Oryon / X-series) hardware — same
Win32 + Direct2D + Direct3D 11 stack as WINDART, same bilingual Smalltalk
front-end, different code generator underneath.

Companion to `WINDOWS_PORTING_PLAN.md` (the x64 design) and `SPRINTS.md`.

**Verification host** (all claims in §2 were measured here, not estimated):

| | |
|---|---|
| CPU | `Snapdragon(R) X - X126100 - Qualcomm(R) Oryon(TM) CPU`, `PROCESSOR_ARCHITECTURE=ARM64` |
| Toolchain | MSVC **14.51.36231** (VS 18 Professional), native `Hostarm64\arm64\cl.exe`, `vcvarsarm64.bat` |
| Build tools | CMake + Ninja (bundled with VS), Python 3.12 **arm64**, Git |
| Graphics | `d3d11.dll`, `d2d1.dll`, `dwrite.dll`, `d3dcompiler_47.dll`, `xaudio2_9.dll`, `d3d10warp.dll` — all present as arm64 |
| Quarry | pristine `dart-lang/sdk` @ **1.24.3**, sparse checkout at `..\sdk-1.24.3` |

The build is **native on the target**. No cross-compilation, no host/target
snapshot split, no simulator.

---

## 1. The core insight — this is *not* the free ride x64 was

`WINDOWS_PORTING_PLAN.md` §1 rests on a true and load-bearing claim: Dart
1.24.3's **Windows x64 JIT shipped in production in 2017** (Dartium,
`dart.exe`), so the VM-core delta was ~zero. **That claim does not transfer to
arm64.** WINDARTARM inherits two mature halves that have *never been compiled
against each other*:

| Half | Status in 1.24.3 | Ever built this way? |
|---|---|---|
| The **arm64 code generator** — all 11 `runtime/vm/*_arm64.cc`: `assembler`, `code_patcher`, `flow_graph_compiler`, `stub_code`, `intrinsifier`, `intermediate_language`, `instructions`, `disassembler`, `debugger`, `runtime_entry`, `cpu` | ✅ Complete, shipped for Android/iOS | **Only ever with GCC/Clang, only ever for Linux/Android/iOS** |
| The **Windows OS layer + embedder** — `virtual_memory_win`, `os_win`, `os_thread_win`, `thread_interrupter_win`, `cpuinfo_win`, `atomic_win`, 17 `bin/*_win.cc` | ✅ Complete, shipped for Dartium | **Only ever for ia32/x64** |

**The port is the seam between them**, and that seam has three properties worth
stating plainly:

1. **It is small and now fully mapped.** Eight files, 20 hunks, one compiler
   flag. Every one is in `port-arm64/windart-arm64.patch`, and every one has
   been compiled (§2). (A0 mapped seven; AS1's full-tree burn-down added
   exactly one more — `os_thread_win.cc` — and nothing else.)
2. **It contains exactly one *capability* change, not just plumbing.** arm64's
   instruction cache is **not coherent** with the data cache. On x64,
   `CPU::FlushICache` is a documented no-op (`cpu_x64.cc:24`, "Nothing to be
   done here"). On arm64 it is mandatory after **every** JIT emission and
   **every** `code_patcher_arm64` self-modification — and 1.24.3 implements it
   only for Android/Fuchsia/Linux, `#error`-ing on anything else. Supplying the
   Windows implementation is the arm64-JIT-defining change, the direct analogue
   of the `sys_icache_invalidate` fix MACDART had to invent for macOS.
3. **The risk MACDART already retired transfers to us for free.** MACDART runs
   this exact VM, this exact arm64 backend, as a JIT on Apple Silicon. That is
   empirical evidence that 1.24.3's arm64 codegen is correct *and* that the VM's
   2017-era, x86-TSO-developed synchronisation survives a weakly-ordered memory
   model. WINDARTARM inherits that evidence. What it does **not** inherit is
   anything about MSVC or the Windows ABI — see §2.6, a class of problem no
   prior port has encountered.

**Honest framing:** WINDART x64 was *build system + GUI*. WINDARTARM is
*build system only* — the GUI, the Smalltalk front-end and every line of Dart
come across untouched (§3) — but its VM-core delta is real engineering, not
zero. It is, however, **bounded and already burned down**.

---

## 2. Verified ground truth — the burn-down, measured

### 2.1 The keystone: MSVC spells arm64 differently

Probed with `cl.exe` targeting arm64:

```
_M_ARM64        IS defined
_WIN64          IS defined
__aarch64__     NOT defined     <- platform/globals.h:252 relies on this
__AARCH64EL__   NOT defined     <- double-conversion/src/utils.h:79 relies on this
```

`runtime/platform/globals.h:252` detects an arm64 host **only** via
`__aarch64__`, a GCC/Clang macro. Compiling the pristine header with
`/DTARGET_ARCH_ARM64` on MSVC arm64 gives, verbatim:

```
platform/globals.h(258): fatal error C1189: #error: Architecture was not detected as supported by Dart.
```

This one line is the keystone, and its **silent** failure mode is worse than its
loud one. Had the arch chain been satisfied some other way while `HOST_ARCH_ARM64`
stayed undefined, `globals.h:353-356` would have quietly defined
**`USING_SIMULATOR`** — and the build would have produced a working binary that
*interprets* arm64 in a software simulator instead of JIT-compiling it. Slow,
plausible-looking, and very expensive to diagnose late. After the one-line fix,
the probe reports:

```
PROBE: USING_SIMULATOR is not defined -- native codegen
```

### 2.2 The full VM-core delta — 8 files, 20 hunks

All in `port-arm64/windart-arm64.patch`. Applies to a pristine 1.24.3 checkout
with **GNU `patch -p1`, zero fuzz, zero rejects** (verified). Rows 1–7 came
from the A0 probe; row 8 from AS1's 591-job `-k 0` burn-down (the *only*
failure in the whole tree).

| # | File | Change | Why |
|---|---|---|---|
| 1 | `platform/globals.h:252` | `\|\| defined(_M_ARM64)` | **Keystone** (§2.1) |
| 2 | `vm/globals.h:113` | arm64 joins the x64 `COPY_FP_REGISTER` branch | Windows branch knew only IA32 (inline `__asm`) and X64 |
| 3 | `vm/atomic_win.h` ×9 | add `\|\| defined(HOST_ARCH_ARM64)` to 9 gates | 9 × `#error Unsupported host architecture`. The bodies are already correct: MSVC's un-suffixed `Interlocked*` lower to full-barrier (seq-cst) arm64 atomics |
| 4 | `vm/cpu_arm64.cc` ×2 | gate the POSIX includes on `!HOST_OS_WINDOWS`; add a `HOST_OS_WINDOWS` branch calling `FlushInstructionCache` | `<sys/syscall.h>` doesn't exist on Windows; `#error FlushICache only tested/supported on Android, Fuchsia, and Linux`. **The JIT-defining change** (§1.2) |
| 5 | `vm/cpuinfo_win.cc` | arm64 reads `ProcessorNameString` from the registry | No CPUID on arm64 → `cpuid.h` stubs `CpuId::field()` to `NULL` → `HostCPUFeatures::Cleanup()`'s `ASSERT(hardware_ != NULL)` fires. Verified the registry path returns the real part name on this box |
| 6 | `vm/thread_interrupter_win.cc` ×3 | arm64 branch: `Pc` / `Fp` / `Sp` **and `X[15]`** | 2 × `#error Unsupported architecture`. See §2.4 — the `X[15]` is the subtle part |
| 7 | `double-conversion/src/utils.h:79` | `\|\| defined(_M_ARM64)` | Same blind spot as #1 |
| 8 | `vm/os_thread_win.cc:180` | arm64 branch reads stack bounds via `NtCurrentTeb()`→`NT_TIB` | `GetCurrentStackBounds` used `__readgsqword` — the GS segment is x86-64-only; arm64's TEB lives in **x18**, which is exactly what `NtCurrentTeb()` compiles to. Same `StackBase`/`StackLimit` fields, same committed-limit semantics |

### 2.3 Compile evidence — the arm64 backend under MSVC

The central unknown of this port was *"does a code generator written for
GCC/Clang compile under MSVC at all?"* With patch #1–#4 and the flag from §2.6,
**it does — 11 of 11 translation units, first try:**

```
assembler_arm64.obj                339,021    intrinsifier_arm64.obj          487,144
flow_graph_compiler_arm64.obj      445,376    intermediate_language_arm64.obj 1,116,957
stub_code_arm64.obj                249,218    code_patcher_arm64.obj           95,038
instructions_arm64.obj              98,280    disassembler_arm64.obj          155,992
debugger_arm64.obj                  56,814    runtime_entry_arm64.obj          42,947
cpu_arm64.obj                        4,429  (with hunk #4)
```

Only `cpu_arm64.cc` failed before patching, exactly as predicted. That is a
strong signal: the arm64 backend is portable C++ and 2017 Dart's coding
standards held up.

> **Caveat, stated plainly:** *compiles* is not *works*. These objects have not
> been linked or executed. §2.3 retires the "will MSVC accept it" risk, not the
> "does it JIT correctly on Oryon" risk — that is milestone **A1** (§5).

### 2.4 The dual stack pointer — arm64 Dart's defining structural quirk

The single most important thing to understand before touching this port.
On arm64, Dart runs on **two** stack pointers:

- **`SPREG = R15`** — the *Dart* stack pointer. `Push`/`Pop` are
  `str/ldr [SP, #±8]` on **R15**, so Dart frames need only 8-byte alignment.
- **`CSP = R31`** — the real hardware SP, used only when entering C++.

`Assembler::EnterFrame` (`assembler_arm64.cc:1088`) maintains the ABI invariants
explicitly, and its own comment names the reason:

```
  // The ARM64 ABI requires at all times
  //   - stack limit < CSP <= stack base
  //   - CSP mod 16 = 0
  //   - we do not access stack memory below CSP
  // ... keep the C stack pointer ahead of the Dart stack pointer and 16-byte
  // aligned for signal handlers.
  sub(TMP, SP, Operand(kMaxDartFrameSize));   // 4096
  andi(CSP, TMP, Immediate(~15));
```

**This is exactly what Windows-on-ARM64 needs, for exactly the same reason** —
Windows delivers exceptions and APCs on the current SP and requires 16-byte
alignment. Dart's design satisfies the Windows requirement as a side effect of
satisfying the POSIX signal-handler requirement. Nothing to change. But two
consequences follow:

1. **The profiler must sample both.** `thread_interrupter_win.cc` on x64 sets
   `csp = dsp = Rsp`. On arm64 they are *different registers*:
   `csp = context.Sp`, `dsp = context.X[SPREG]` — mirroring
   `signal_handler_linux.cc:75`, which reads `mcontext.regs[SPREG]` on arm64.
   Setting `dsp = Sp` would compile fine and make **every Dart stack walk in the
   profiler silently wrong**. Hunk #6 gets this right.
2. **`CSP = SP − 4096` interacts with Windows guard pages** — see §4.2.

### 2.5 Snapshots are architecture-tagged (and the existing guard already saves us)

`Dart::FeaturesString` (`dart.cc:658`) embeds the target arch in every snapshot:
`" arm64"` vs `" x64-win"`. `SnapshotReader::VerifyVersionAndFeatures`
(`snapshot.cc:611`) compares it on load. Therefore:

- **Every existing snapshot artefact is x64 and will be rejected**: the baked
  `snapshot_gen.cc` arrays, the `.bin` files beside `dartui.exe`, and the
  `snapshot:vm` / `snapshot:isolate` blobs inside
  `%USERPROFILE%\.windart\workspace.sqlite`. All must be regenerated by an
  arm64 `gen_snapshot`.
- **Good news:** `win_host.cpp`'s `WindartSnapshotCompatible` already compares
  the version+features header of a candidate DB blob against the baked array and
  **falls back rather than aborting** on mismatch. Because the features string
  carries the arch, that guard rejects a stale x64 blob *automatically*. The
  world DB is already forward-safe across the arch switch — a genuinely nice
  property of the existing W1 design.
- **One trap to note:** the arm64 features tag is just `" arm64"`, with **no
  OS discriminator** (unlike x64, which distinguishes `x64-win` from
  `x64-sysv`). A MACDART-generated arm64 snapshot would therefore *pass* the
  version check on WINDARTARM. Don't mix them; consider adding a `-win` suffix
  locally if MACDART artefacts ever share a machine.

### 2.6 A collision nobody has hit before: `arm64_neon.h` vs the Dart assembler

Because Dart's arm64 assembler has never been compiled by MSVC, this class of
problem is unexplored territory. Swept it exhaustively — intersected all
**5,013** function-like macros in MSVC's `arm64_neon.h` against every identifier
used in Dart's arm64 backend. The result is reassuringly small: **exactly one
collision.**

```
arm64_neon.h:7943:  #define mvn(src) neon_not(src)
```

against `Assembler::mvn` (`assembler_arm64.h:1062`), used in
`intermediate_language_arm64.cc` and `intrinsifier_arm64.cc`. It arrives via
`platform/utils_win.h` → `<intrin.h>` → `arm64_neon.h`, and manifests as
`warning C4002` + `error C2065: 'rm': undeclared identifier`.

**This needs no source patch.** The alias block is guarded
(`arm64_neon.h:27`), and MSVC provides a documented opt-out:

```cmake
add_compile_definitions(_ARM64_NO_EXTENDED_INTRINSICS)
```

That is the entire fix, and it is why the delta stays at 8 files.

---

## 3. What changes, layer by layer

The x64 plan's layering holds; the *effort profile inverts*. x64 was
"Layer 0 free, Layer 2 expensive". arm64 is "Layer 0 real, **Layer 2 free**".

```
┌─ Layer 3: PORTABLE Dart — ZERO CHANGES ─────────────────────────────────┐
│  workspace.dart (the IDE, 120KB), language.dart, every demo and game,   │
│  win.dart, cocoa.dart, the .mst Smalltalk corpus, the TCL control plane.│
├─ Layer 2: dart_win32 + dart_st — ~ZERO CHANGES ─────────────────────────┤
│  win_host / win_natives / win_callbacks / win_view / win_canvas /       │
│  win_toolbar / gp_engine_d3d / gp_natives / gp_audio / gp_synth /       │
│  the SQLite, workspace, debug, userlib, world-io natives.               │
│  Swept for x86-isms: NONE found. Win32/D2D/D3D11/XAudio2/DirectWrite    │
│  are all fully supported on arm64 and verified present on this host.    │
│  The ST compiler (st_lexer/parser/loader/flow_graph_builder, 250KB)     │
│  emits Dart flow-graph IR, NOT machine code — it is arch-agnostic by    │
│  construction and ports for free.                                       │
│  ONE exception: the ST FFI trampoline — see §4.4.                       │
├─ Layer 1: BUILD SYSTEM — the mechanical work ───────────────────────────┤
│  gen_sources.py filter re-inversion · CMakeLists arch defines ·         │
│  build.ps1 vcvarsarm64 · extract.py path de-pinning (§3.2)              │
├─ Layer 0: VM CORE — 7 files, 19 hunks, 1 flag (§2, ALREADY BURNED DOWN) │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.1 `gen_sources.py` — re-invert the arch filter

Keep `_arm64`, drop everything else. Note `_arm[\._]` matches `assembler_arm.cc`
but **not** `assembler_arm64.cc` (`_arm` must be followed by `.` or `_`), so the
32-bit ARM backend drops out while arm64 survives — the same trick the x64
version uses in reverse.

```python
# KEEP _arm64; drop the other backends.
OTHER_ARCH_RE = re.compile(r"(_ia32[\._]|_x64[\._]|_arm[\._]|_mips[\._]|_dbc[\._]|^simulator_)")
# OS filter is UNCHANGED — still keep _win.
OTHER_OS_RE   = re.compile(r"(_linux[\._]|_macos[\._]|_android[\._]|_fuchsia[\._]|_openbsd[\._]|_solaris[\._])")
```

### 3.2 `CMakeLists.txt` deltas

```cmake
add_compile_definitions(
  TARGET_ARCH_ARM64                # was TARGET_ARCH_X64
  _ARM64_NO_EXTENDED_INTRINSICS    # §2.6 — arm64_neon.h's mvn() vs Assembler::mvn
  DART_IO_SECURE_SOCKET_DISABLED)  # unchanged
```

- `HOST_ARCH_ARM64` still **auto-derives** from `_M_ARM64` (after patch #1) —
  so, exactly as the x64 build documents, do *not* define it manually.
- `list(FILTER VM_CC EXCLUDE REGEX "malloc_hooks_(tcmalloc|jemalloc|arm64)\\.cc$")`
  — `arm64` replaces `x64`; `malloc_hooks_unsupported.cc` remains the real impl.
- The MSVC warning-suppression set, `/bigobj`, `/permissive`, `/FI msvc_compat.h`,
  `/Z7`, the whole snapshot pipeline, `WIN_SYS_LIBS`, and every `dart_win32` /
  `dart_st` target: **unchanged**. `advapi32` (already listed) covers hunk #5's
  `RegGetValueA`.

### 3.3 `build.ps1` / `extract.py` — de-pin the paths

Both are hard-wired to an `E:` drive that need not exist (`SrcDir/BuildDir =
e:\windart-talk\...`, `SRC = e:\dart_origins\sdk-1.24.3`, and `TREE` in
`CMakeLists.txt`). Parameterise these before anything else — it costs minutes
now and is a recurring papercut otherwise. `build.ps1` also needs
`vcvarsarm64.bat` in place of `vcvars64.bat`, and the VS-bundled CMake/Ninja are
fine (no separate install needed on this host).

---

## 4. Risks, ranked for arm64

> **AS3 update (2026-08-12).** Risks 1 and 6 are now **retired by measurement**,
> and a *new* arm64-only defect was found in their place — see
> `port-arm64/AS3_NOTES.md` §3. Summary: 500 reload rounds × 400 calls into
> freshly compiled and patched code produced **zero stale reads** (risk 1 clean);
> 8/8 source-error cases stayed catchable with no VM abort (risk 6 clean, no
> arm64 change). But with **background compilation + a low optimisation
> threshold + genuinely-changed reloads**, arm64 deterministically trips
> `~StackResource`'s `ASSERT(top == this)`; x64 built from the same tree passes
> the identical run. Workaround: `--no_background_compilation`. Default flags are
> unaffected. Root-cause deferred to AS7.

**1. Non-coherent i-cache — correctness, and it will not fail loudly.**
Hunk #4 puts `FlushInstructionCache` in `CPU::FlushICache`, and the VM calls it
from the right places (it had to, for Android). The residual risk is a path
where 1.24.3 writes code and *doesn't* call it because x86/no-op semantics made
it invisible — hot-reload, `Become`, inline-cache patching and deopt are the
places to audit. Symptom: rare, non-deterministic crashes or wrong branches
under sustained JIT churn, i.e. **exactly what the workspace's morphing
hot-reload does all day**. Mitigation: bring up under `DEBUG`, exercise
Accept/reload hard (T4/S7 tests), and if anything smells, temporarily widen the
flush to whole code regions to confirm the hypothesis before narrowing again.

**2. `CSP = SP − 4096` vs Windows guard pages.** Dart parks the hardware SP one
page below the Dart SP (§2.4). Windows commits thread stacks lazily via a guard
page and expects **sequential** page touching. Frames descend gradually so CSP
stays one page ahead — the arrangement should be benign, and it is the same
arrangement that works under POSIX signal delivery. But Windows' guard-page
contract is stricter than POSIX's, and exception delivery *at* CSP is the exact
moment it matters. Mitigation: `SetThreadStackGuarantee` on VM threads, verify
`OSThread::GetSpecifiedStackSize` / `--stack_size` interaction, and deliberately
test deep recursion to `StackOverflowError` — a case that exercises the guard
page on purpose.

**3. Weak memory ordering.** Largely retired by MACDART's Apple Silicon
evidence (§1.3) and by hunk #3 using full-barrier `Interlocked*`. Residual: the
VM's *non-atomic* fast paths, where x86 TSO gave free ordering. Apple Silicon is
also weakly ordered, so MACDART covers most of it — but Oryon is not an Apple
core, and store-buffer/prefetch behaviour differs in the tail. Treat any
intermittent GC or isolate-handoff bug as memory-ordering-first.

**4. The ST FFI trampoline — a *definite* build break in owned code.**
`port-win/dart_st/st_natives.cc:1359` compiles a GCC-style `__asm__` AAPCS64
trampoline under `#if defined(TARGET_ARCH_ARM64) || defined(__aarch64__)`.
WINDARTARM defines `TARGET_ARCH_ARM64`, so **this block will now compile for the
first time on Windows — and MSVC arm64 has no `__asm__` at all** (verified:
`error C4430` / `C2440`; MSVC supports no inline assembly whatsoever on arm64).
This is the one Layer-2 change the port requires. Two options:
  - **(a) Keep FFI off (recommended for bring-up).** Tighten the gate to
    `&& !defined(_MSC_VER)`. `ST_ffiCall` already throws
    `"FFI: not yet supported on windart"` under `_WIN32`, so behaviour is
    unchanged from the shipping x64 build — this is a *no-regression* fix.
  - **(b) Do it properly later.** Move the trampoline to a `.asm` file built by
    `armasm64.exe` (a CMake `enable_language(ASM_MARM)` / custom rule). Note the
    Windows arm64 ABI is *not* identical to AAPCS64 — **x18 is the TEB and must
    never be clobbered**. Fortunately 1.24.3 already reserves R18 unconditionally
    (`constants_arm64.h:160`, with an unimplemented `TODO(rmacnak): Only reserve
    on Mac & iOS` — leave that TODO alone, it is load-bearing for us).

> **UMA finding (2026-08-12).** Measured ahead of AS5 — see
> `port-arm64/GPU_UMA_DESIGN.md`. The Adreno X1-45 reports **`UMA: YES`** with
> 16 GB shared memory, and mapped GPU memory is **fully cached, reading at
> normal RAM speed** (on a discrete GPU it is write-combined and reads are
> 10–100× slower). Plotting straight into mapped memory instead of today's
> `UpdateSubresource` is **5.7–19.4× faster**, which turns the *deferred*
> direct-framebuffer feature into the pane's biggest available win. Also
> measured: `MapOnDefaultTextures` is advertised but a trap (only
> `BindFlags = 0`, and O(size) cache maintenance at `Unmap`), and Adreno is a
> **tile-based deferred renderer**, which has its own render-pass consequences.

**5. D3D11 on Adreno.** The engine asks for FL 11_1→11_0 with a WARP fallback,
compiles HLSL at runtime via `D3DCompile` at `vs_5_0`/`ps_5_0`/`cs_5_0`, and
uses `DXGI_FORMAT_R8_UINT` index textures plus compute-shader blitters. Adreno's
D3D11 driver exposes FL 12_1, and `d3dcompiler_47.dll`/`d3d10warp.dll` are both
present as arm64 on this host, so this *should* be uneventful. Rated low, but
it is untested silicon: the per-scanline "copper" palette trick and the compute
blitter are the parts most likely to expose a driver difference. `gpsnap` PNG
readback gives a deterministic, headless way to diff against x64 output.

**6. `longjmp` + SEH.** `windart-port.patch`'s `longjump.cc` hunk skips
`StackResource::UnwindAbove` under `_MSC_VER` because MSVC's `longjmp`
SEH-unwinds and would run the destructors twice. Windows arm64 also uses
table-driven SEH and its `longjmp` also unwinds, so the existing `_MSC_VER` gate
remains correct — **no change needed**, but verify early (a scan/parse error on
a bad source file is the cheap repro, and it aborts the VM if this is wrong).

---

## 5. Phased plan

Sprints mirror `SPRINTS.md`'s discipline: bounded, with objective exit criteria.
**A0 is already complete** — this document and `port-arm64/windart-arm64.patch`
are its artefacts.

**A0 — Seam mapped. ✅ DONE.** The 7-file / 19-hunk patch applies clean to
pristine 1.24.3; 11/11 arm64 backend TUs compile under MSVC arm64; the
`arm64_neon.h` collision is closed by one flag. *Exit met.*

**A1 — `dart.exe` JITs on Oryon.** De-pin the paths (§3.3), re-invert
`gen_sources.py`, flip the CMake defines, apply both patches, build
`dart_engine` → `gen_snapshot` → regenerate the **arm64** core snapshot (§2.5) →
link `dart.exe`. **Exit:** `dart.exe hello.dart` prints, executing JIT-compiled
arm64. *This is the milestone that converts §2.3's "compiles" into "works".*
Run `DEBUG` first — `dart.cc:110-118`'s `CHECK_OFFSET` assertions for
`TARGET_ARCH_ARM64` are a free built-in self-test of the object layout.

**A2 — `dart:io`, isolates, hot-reload.** No arm64-specific work expected;
this is a regression pass over S3's surface. **Exit:** `io_test.dart`,
`isolate_test.dart`, `Dart_WorkspaceReloadSources` all green. Stress reload
hard here — it is the primary i-cache risk probe (§4.1).

**A3 — `dartui.exe` up.** Link `dart_win32` + `dart_st`; apply the §4.4(a) FFI
gate. **Exit:** the workspace window opens, the class browser reads the running
VM, Do-It evaluates.

**A4 — Canvas, game pane, audio.** D2D demos, then D3D11 games. **Exit:**
Mandelbrot/plasma/boids render; Invaders + Brickout run; `gpsnap` readback
diffs clean against the x64 reference PNGs.

**A5 — Bilingual + world DB.** Re-bake the snapshot into the SQLite image
(§2.5); load the `.mst` corpus; run the TCL regression suite verbatim.
**Exit:** `tcl\dartui.tcl` and the `test_*.tcl` battery pass.

**A6 — Soak + polish.** Long-running hot-reload/morph soak (the real i-cache
and memory-ordering test), profiler validation (hunk #6's `X[15]` — check Dart
stack walks are sane), guard-page/deep-recursion test (§4.2), packaging.

---

## 6. Decisions worth taking before A1

1. **Repo shape.** Fork, branch, or arch-parameterise in place? `port-win/` is
   ~95% arch-neutral; a `WINDART_ARCH` CMake variable selecting the
   `gen_sources.py` regex, the `TARGET_ARCH_*` define and the `vcvars` script
   would keep one tree building both — cheaper than a fork that immediately
   starts diverging. `port-arm64/` currently holds only the patch, deliberately.
2. **Patch layering.** Keep `windart-arm64.patch` separate from
   `windart-port.patch` (recommended — the x64 build stays byte-identical and
   the arch seam stays legible), or merge with `#if` guards?
3. **`msvc_compat.h`.** Still empty. `_ARM64_NO_EXTENDED_INTRINSICS` could live
   there instead of in CMake; CMake is the better home (it is a configuration
   choice, not a compiler bug shim), but the shim exists precisely for this
   class of thing.
4. **`st-tree.patch`.** Unexamined against arm64. It is described as embedder
   registration + compiler/inliner routing hooks + `noSuchMethod` patches — all
   arch-neutral by description, but confirm before A3.

---

## 7. Reuse accounting — honest

| Source | Contributes | Size |
|---|---|---|
| **Upstream Dart 1.24.3** | The entire VM, the arm64 code generator, the Windows OS layer, the Windows embedder | ~435k LOC, free |
| **WINDART (this repo)** | The whole build system, the entire `dart_win32` GUI/D2D/D3D11/XAudio2 layer, the `dart_st` Smalltalk front-end, every Dart app and the IDE | ~everything above Layer 0, free |
| **MACDART** | *Evidence*, not code: proof that 1.24.3's arm64 JIT is correct and survives weak memory ordering | risk retirement |
| **WINDARTARM (new)** | 7 files, 19 hunks, 1 compiler flag, 1 FFI gate | ~250 lines |

The port is small because both parents are good. The work is proving the seam —
and §2 is that proof, up to the point where it needs a linker.
