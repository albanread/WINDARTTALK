# WINDARTARM — Sprint plan (execution)

Companion to `WINDOWS_ARM64_PORTING_PLAN.md` (the design). This is the
executable breakdown: bounded sprints with objective exit criteria, in the
discipline of `SPRINTS.md`. Sprint IDs are `AS*` to avoid colliding with the
plan's phase names; the mapping is at the bottom.

## Ground truth (probed 2026-08-12, ON the target)
- **The build host IS the target**: Snapdragon X (`X126100`, Oryon), Windows 11
  arm64. Native build — no cross-compile, no simulator, and `gen_snapshot`
  runs in-build exactly as it does on x64.
- Toolchain: **MSVC 14.51.36231** (VS 18 Professional), native arm64 compiler
  (`...\VC\Tools\MSVC\14.51.36231\bin\Hostarm64\arm64\cl.exe`) via
  `C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvarsarm64.bat`.
  CMake + Ninja are the VS-bundled copies
  (`Common7\IDE\CommonExtensions\Microsoft\CMake\{CMake\bin,Ninja}`) — no
  separate install. Python 3.12 **arm64**, Git 2.55.
- Reference quarry: `C:\projects\WINDARTARM\sdk-1.24.3` (sparse checkout of
  dart-lang/sdk @ 1.24.3, read-only).
- Repo: `C:\projects\WINDARTARM\WINDARTTALK`.
- **A0 is done** (see plan §2): `port-arm64\windart-arm64.patch` — now **8
  files, 20 hunks** after AS1's burn-down added `os_thread_win.cc` — applies
  `-p1` to pristine 1.24.3 with zero fuzz/rejects; 11/11 arm64-backend TUs
  compile under MSVC arm64 with `_ARM64_NO_EXTENDED_INTRINSICS`.
- Prereqs probed: the SQLite amalgamation at `extract.py`'s default cargo-cache
  path **exists on this box**; `tclsh` is **NOT installed** (needed by AS6 —
  install any Tcl 8.6 for Windows before then; the TCL suite is portable).

## Snapshots — the rule carried through every sprint
Snapshots are **architecture-tagged** (`Dart::FeaturesString` embeds `" arm64"`
vs `" x64-win"`; the reader rejects mismatches). Therefore every snapshot
artefact — the baked `snapshot_gen.cc` arrays, the `.bin` files beside the
exes, the `snapshot:vm`/`snapshot:isolate` blobs in
`%USERPROFILE%\.windart\workspace.sqlite` — is **regenerated on-target** by the
sprint that produces it (AS2 the core snapshot; AS4/AS6 the image blobs).
`WindartSnapshotCompatible` already falls back past a stale x64 blob instead of
aborting, so an old world DB degrades gracefully. Never import a MACDART arm64
snapshot: the `" arm64"` tag carries no OS discriminator and it would pass the
check.

## Workspace layout (de-pinned in AS1)
- `WINDARTTALK\port-win\` — owned build scaffolding; gains an arch parameter,
  stays the single build system for both targets.
- `WINDARTTALK\port-arm64\` — the arm64 VM-core patch + per-sprint
  `AS*_NOTES.md` engineering logs as they land.
- `C:\projects\WINDARTARM\tree\` — extracted + patched source tree. Generated.
- `C:\projects\WINDARTARM\build-arm64\` — CMake/Ninja out-of-source build dir.
  Generated. (A future x64 build of the same tree uses `build-x64\`.)

## Risk note carried into every sprint
arm64's i-cache is **not coherent** (plan §1.2 / risk 1). Any intermittent
crash, wrong branch, or "impossible" state under JIT churn is triaged as a
**missing i-cache flush first**, memory ordering second, everything else third.
`Debug` config (VM `DEBUG` asserts + `CHECK_OFFSET` self-tests) is the default
until AS7.

---

## AS1 — Arch-parameterised build system; the full engine compiles  ✅ DONE 2026-08-12
**Result:** one burn-down cycle. 591 build jobs, exactly ONE failing TU —
`os_thread_win.cc`'s `__readgsqword` (x86 GS-segment TEB read; arm64 reads the
TEB via `NtCurrentTeb()` = x18). Fix folded into the patch (now 8 files /
20 hunks, re-verified against pristine). See `port-arm64\AS1_NOTES.md`.
**Goal:** one owned build system that builds either arch, and the complete
engine + native static libs compiling for arm64. **Exit:** CMake configures
with `-DWINDART_ARCH=arm64` and `dart_engine_nosnap`, `dart_engine_snap`,
`dart_builtin`, `dart_io`, `dart_win32`, `dart_st` all compile clean (or a
categorised, shrinking error burn-down if stalled).
- De-pin the three path pins: `extract.py:28-29` (`SRC`/`DEST` → env vars
  `WINDART_SDK_SRC`/`WINDART_TREE` with the layout above as defaults),
  `CMakeLists.txt:35` (`TREE` → cache variable), `build.ps1:22-24`
  (`-Arch arm64|x64` selects `vcvarsarm64.bat`/`vcvars64.bat`; repo-relative
  `SrcDir`, arch-suffixed `BuildDir`).
- `extract.py`: apply `port-arm64\windart-arm64.patch` after
  `windart-port.patch` + `st-tree.patch` (shared-file hunks are net-zero-line
  and far apart — verified independent; still run `--dry-run` first in-script).
- `gen_sources.py`: `--arch` flag with per-arch `OTHER_ARCH_RE` (arm64 keeps
  `_arm64`, drops `_ia32|_x64|_arm[\._]|_mips|_dbc|simulator_`); CMake's
  `dart_sources()` passes `${WINDART_ARCH}`.
- `CMakeLists.txt`: `WINDART_ARCH` selects `TARGET_ARCH_ARM64|TARGET_ARCH_X64`;
  add `_ARM64_NO_EXTENDED_INTRINSICS` (arm64 only — the `arm64_neon.h` `mvn`
  macro, plan §2.6); `malloc_hooks_(tcmalloc|jemalloc|${WINDART_ARCH})` filter;
  do **not** define `HOST_ARCH_*` (auto-derives from `_M_ARM64` post-patch).
- `dart_st\st_natives.cc:1359`: tighten the trampoline gate with
  `&& !defined(_MSC_VER)` (MSVC arm64 has no `__asm__`; `ST_ffiCall` already
  throws on `_WIN32` — no behaviour change, plan risk 4a).
- Watch item: the ~430 portable TUs compiled under x64 MSVC already; arm64
  deltas should be null. Log anything new in `port-arm64\AS1_NOTES.md`.

## AS2 — gen_snapshot + dart.exe: the arm64 JIT milestone  ✅ DONE 2026-08-12
**Result:** `dart.exe hello.dart` prints on the Snapdragon; `gen_snapshot`
ran natively in-build (the arm64 core snapshot: 905,004 + 266,231 B);
`--compiler_stats` on `test\jit_tierup.dart` shows 350 compiled / **1
optimized** — tier-up + arm64 code patching + i-cache flush proven end to end.
Bonus smokes green: isolate / mirror / io (io_test needed its own dead-`E:`
path pins removed). See `port-arm64\AS2_NOTES.md`. Next: AS3.
**Goal:** link the tools, regenerate the **arm64** core snapshot, run real JIT
code. **Exit:** `build-arm64\dart.exe hello.dart` prints via JIT-compiled
arm64, and a hot-loop script shows `--compiler_stats` functions-optimized > 0
(tier-up proven, not just entry).
- Order: `dart_bootstrap` first (nosnapshot — proves VM+JIT with no snapshot
  dependency, the x64 S2 contingency path), then `gen_snapshot` → the two
  `.bin` → `create_snapshot_file.py` → `dart`.
- `Debug` first: `dart.cc:110-118`'s `CHECK_OFFSET` block for
  `TARGET_ARCH_ARM64` runs at VM init — a free object-layout self-test on
  first launch.
- First-run triage order (if it dies): `CHECK_OFFSET` assert → stub entry
  (`GenerateCallToRuntimeStub` / `SetupDartSP`) under windbg → i-cache
  (bracket `FlushInstructionCache` wider) → then everything else.

## AS3 — dart:io + isolates + the hot-reload/i-cache probe  ✅ DONE 2026-08-12
**Result:** exit met, plus one real arm64-only VM bug found and worked around.
i-cache **clean**: 500 reload rounds × 400 calls into freshly compiled+patched
code, zero stale reads. longjmp/SEH **clean**: 8/8 error cases catchable, VM
never aborts — the `_MSC_VER` gate needs no arm64 change (independently probed:
arm64 `longjmp` does run destructors). **BUG:** with background compilation +
`--optimization_counter_threshold=100` + genuinely-changed reloads, arm64 trips
`allocation.cc` `top == this` at round 7, deterministically; x64 built from the
same tree passes the identical run. Workaround `--no_background_compilation`;
default flags unaffected. Full triage in `port-arm64\AS3_NOTES.md`; root-cause
deferred to AS7 (needs a debugger — none installed).
**Goal:** the embedder surface regression-passes; reload churn stresses the
non-coherent i-cache on purpose. **Exit:** `io_test.dart`,
`isolate_test.dart`, `mirror_test.dart`, `stdin_test.dart` green; a new
`test\reload_churn.dart` (edit-source → `Dart_WorkspaceReloadSources` → call
morphed function → assert new behaviour, ×500) survives; a deliberate syntax
error in a loaded file produces a *catchable* error, not an abort (verifies the
`longjump.cc` `_MSC_VER` SEH gate holds on arm64 SEH).
- No new arm64 code is expected in this sprint; it exists to convert plan
  risks 1 and 6 from "argued" to "exercised".

## AS4 — dartui.exe: the IDE up on Oryon  ✅ DONE 2026-08-12
**Result:** `dartui.exe workspace.dart selftest` → exit 0, `SELFTEST: done`,
**36 PNGs**. All 9 tabs materialize; live class browser (16 libs, real on-disk
SDK source); Do-It in **both** languages (`(2+3)*7 => 35`, `25 sqrt => 5.0`);
Accept + **morphing hot-reload** keeping live state across a class-shape change,
plus Revert and the syntax gate; **full debugger** (breakpoint → pause → stack →
locals → frame-eval `n*n => 25` → step → resume). Fixed two *pre-existing* repo
bugs: 13 dead `E:` pins in workspace.dart, and a selftest calling `press` on a
never-assigned `calc` which killed the UI isolate (x64 fails identically).
**Bonus:** the D3D11 game pane already runs — coindash 83 frames + tiletest 98
frames on Adreno with XAudio2 SFX. See `port-arm64\AS4_NOTES.md`.
**Goal:** the full GUI host + view-server + workspace on arm64. **Exit:** the
9-tab workspace opens; the class browser reads the live VM; Do-It evaluates;
Accept + morphing hot-reload works; the `WINDART_SELFTEST` headless
button-click round-trip passes.
- Link `dartui` (dart_win32 + dart_st are already compiled from AS1); the
  `.rc`/manifest path is arch-neutral.
- World DB: let `WindartSnapshotCompatible` skip the stale x64 blobs, then
  re-bake via "Bake snapshot → image" so the image is self-hosting again
  (arm64 blobs).
- The Direct2D materializer, RichEdit editor, tables, toolbar: expected
  zero-change — this sprint is where that claim is tested.

## AS5 — Canvas demos + D3D11 game pane + XAudio2 on Adreno
**Head start from AS4:** the engine already renders — coindash (83 frames) and
tiletest (98 frames) ran live on Adreno with XAudio2 SFX, `gpSnap` +
`gpSnapPresent` both OK, indexed/sprite/tile/text layers all working first try.
**Prereq:** batch-fix the 43 remaining `E:` pins across `test/` + `tcl/` (they
block the demo battery and the TCL suite).
**Goal:** the rendering stack on untested silicon. **Exit:** the demo battery
renders (bounce, lissajous, mandelbrot, plasma, copper, pixmap, tiletest,
fonttest, rgbatest, keyecho); Pong → Invaders (incl. the HLSL-starfield
variant) → Brickout run live with SFX; `gpsnap` readback matches a **WARP
reference** byte-for-byte where the pipeline is integer/indexed (the blitter,
the copper palette), tolerance-diffed where float shading legitimately varies.

**+ UNIFIED MEMORY (measured up front — `port-arm64\GPU_UMA_DESIGN.md`).**
The Adreno X1-45 reports `UMA: YES` with 16 GB shared; the CPU→GPU transfer the
engine pays for today need not exist. Three tiers, in order:
- **Tier 1 (do first, standalone, no protocol change):** replace
  `UpdateSubresource` with `DYNAMIC` + `Map(WRITE_DISCARD)` in
  `GpIndexedPane::upload()` (`gp_engine_d3d.cpp:446`) and the constant-buffer
  sites (459/509/707/1038). **~8× on upload**, zero Dart-side risk.
- **Tier 2:** implement the deferred S6b direct-framebuffer —
  `Win_gpBackbuffer()` returns an `ExternalTypedData` over the mapped pointer,
  valid for ONE frame (Map at frame start, Unmap before the draw; the pointer
  moves every frame under `WRITE_DISCARD`). **Total 5.7–19.4× vs today.**
  Invalidate the handle at Unmap so a stale one fails closed.
- **Tier 3:** exploit coherent cached reads — mapped memory reads at *normal
  RAM speed* here (impossible on a discrete GPU), making per-frame `gpsnap`
  (0.14 ms @ 640×400) and CPU read-modify-write effects practical.
- **Do NOT build on `MapOnDefaultTextures`** despite the cap saying YES: only
  `BindFlags = 0` is accepted, and its `Unmap` cache-maintenance cost is
  O(size), losing to `WRITE_DISCARD` at every size tested (double-buffering
  does not rescue it). Full negative result in the design note.
- **TBDR:** Adreno is tile-based deferred. Verify full `ClearRenderTargetView`
  at pass start (free on TBDR; partial writes force a tile load) and check the
  5-layer composite / compute blitter for render-target ping-pong.
- Trick: force `D3D_DRIVER_TYPE_WARP` for a deterministic reference run on the
  same machine, then diff Adreno against WARP — isolates driver deltas from
  engine bugs without needing the x64 box.
- Runtime `D3DCompile` at `vs_5_0/ps_5_0/cs_5_0` and `DXGI_FORMAT_R8_UINT` are
  well inside Adreno's FL 12_1 — watch the compute blitter and per-scanline
  palette first if anything looks off (plan risk 5).

## AS6 — Bilingual Smalltalk + world DB + the TCL battery
**Head start (2026-08-12, `port-arm64\ST_WORLD_FINDINGS.md`):** the world is on
MACDARTV1's **`dartui-workspace`** branch (not `main`, and never in this repo).
All 97 files boot on arm64 (`st_world_run`: collections, Dictionary, Interval,
SortedCollection, Fraction, WriteStream, select/inject — all correct), and the
bilingual browser lists **179 Smalltalk classes** beside the Dart libraries with
real `.mst` source. `ws_language.dart` compiled 1411 fns / 148 optimized with
the world loaded. **The class library needs no porting.** The bounded remaining
work is **19 Cocoa/POSIX-bound classes across 26 files** — re-point them at the
`dart:win` view-server, the same `Mac-ST → Windows-ST` move galaxigans got.
Corpus selected by `WINDART_ST_WORLD` (workspace.dart + test_c2_browser.tcl).
Path pins in `test/`+`tcl/` are **done** (43 sites, 26 files).
**Goal:** the ST front-end and the whole control plane, verbatim. **Exit:**
`st_one`/`st_probe`/`st_battery`/`st_cogbench` pass; `galaxigans.mst` loads
and plays (headless + live); world export/import round-trips; the
`tcl\test_*.tcl` suite + `tcl\dartui.tcl` pass unmodified.
- ~~Prereq: install a Tcl 8.6 `tclsh`.~~ **Not needed** — Git for Windows already
  ships a **native arm64** one at `C:\Program Files\Git\clangarm64\bin\tclsh.exe`
  (8.6.18, PE machine 0xAA64). `dartui.tcl` needs no `package require` at all.
- **TCL battery: 11 of 12 PASS on arm64** (`port-arm64\AS6_NOTES.md`), driving a
  live `dartui.exe --observe` over the vm-service WebSocket: bilingual Do-It,
  browser, editor, app pane, find/senders, catalog, inspector, method-slicer, ST
  post-mortem debugger, plus a new `test_arm64_smoke.tcl`. The one failure,
  `test_c5_game.tcl`, aborts the VM at `intermediate_language.h:3345` — **x64
  from the same tree fails identically**, and it is isolated to
  `80_gamepane_wiring.mst` + `83_gamepane_direct.mst`.
- The ST compiler emits flow-graph IR, not machine code — this sprint proves
  the "arch-agnostic by construction" claim end to end, including
  `st_flow_graph_builder` driving the arm64 backend for the first time.
- Re-bake the snapshot blob into the image; verify boot-from-image
  (DB → .bin → baked fallback chain) with the arm64 tags.

## AS7 — Soak, profiler truth, packaging (+ the AS3 bug, + optional real FFI)
**Carried in from AS3** (WinDbg for arm64 is now **installed** — `WinDbgX.exe`
via winget, 2026-08-12):
- ~~**Root-cause the StackResource inversion.** Repro in `AS3_NOTES.md` §3.
  Hypothesis to test: arm64's dual stack pointer (`CSP = (SP−4096) & ~15` per
  `Assembler::EnterFrame`) makes C++ StackResource addresses non-monotonic
  across runtime entries taken at different Dart depths, breaking the
  address-ordered unwind.~~
  **DONE — and it was never arm64's fault.** Not the dual stack pointer, not
  codegen, not the i-cache: the port was inheriting CMake's default **`/EHsc`**
  (exceptions ON), which upstream Dart never uses. With C++ EH on, `longjmp`
  performs an SEH unwind that runs C++ destructors — a *second* unwinder
  walking the same StackResource chain `LongJumpScope::Jump` already unwinds by
  hand. That is why neither blanket policy worked: both on = double-destruct
  (`syntax_recover` aborts); manual off = the SEH unwind reaches
  `~LongJumpScope` with the chain moved underneath it (`reload_churn` aborts at
  round 7). Fixed by adopting upstream's posture — `/EHs-c- /D_HAS_EXCEPTIONS=0`
  plus an unconditional `UnwindAbove`. **Both** gates now pass on **both**
  architectures, `--no_background_compilation` is no longer needed, and the
  latent hazard on x64 is gone too. Written up in `port-arm64/AS7_NOTES.md` §2.
  The working crash stacks from §1 found it in minutes.
- ~~**Restore native crash stacks.** `COPY_FP_REGISTER` on arm64 currently
  yields SP, not FP (patch hunk #2 takes the x64 fallback), so `DumpStackTrace`
  walks one frame. Needs an `armasm64` helper to read x29.~~
  **DONE — and the stated approach was wrong.** There is no x29 chain to read:
  Windows unwinds from `.pdata`, so MSVC may put the saved `{x29,x30}` pair
  anywhere in a frame or omit it, and no `COPY_FP_REGISTER` value can make the
  frame-pointer walk follow C++ frames (which is why upstream's x64 branch also
  just returns SP). Fixed by unwinding with `RtlVirtualUnwind` instead — 17
  symbolized frames where there were 2, on **both** architectures. Measured in
  `port-arm64/probes/fp_probe{,2}.cpp`; written up in `port-arm64/AS7_NOTES.md`.

**Goal:** durability and the loose ends. **Exit:** a multi-hour morph/reload
soak (TCL-driven) runs clean; the VM-tab profiler shows sane Dart stacks
(hunk #6's `dsp = X[15]` — wrong would be silent, plan §2.4); deep recursion
on N threads yields `StackOverflowError`, never an access violation (the
guard-page probe, plan risk 2); a relocatable zip runs on a second WoA
machine from a clean directory.
- Optional, behind its own flag: the real Win-arm64 FFI trampoline as a
  `.asm` built by `armasm64.exe` — MS arm64 ABI ≈ AAPCS64 with **x18 = TEB,
  never touched** (1.24.3 already reserves R18; the `TODO(rmacnak)` saying to
  un-reserve it is load-bearing here — leave it).

---

## Sprint → plan-phase map
AS1 + AS2 = plan **A1** · AS3 = **A2** · AS4 = **A3** · AS5 = **A4** ·
AS6 = **A5** · AS7 = **A6**. (A0 was the seam-mapping work — done.)

## Team & cadence
- **Architect:** owns the arch parameterisation decisions (plan §6),
  adversarially reviews each sprint's artefacts + logs, gates on exit
  criteria. "It compiles" is not accepted without the object/log; "it runs"
  is not accepted without the printed output or the gpsnap PNG.
- **Agents (2–3):** bounded work, objective success, read-only on the quarry;
  write only under `port-win\`/`port-arm64\` + the generated `tree\`/`build-*\`.
- **Loop:** dispatch → build/test on-target → review artefacts → integrate →
  next. The target being the dev box removes the deploy step from the loop —
  use that: every sprint ends with the binary actually executed, not shipped
  somewhere to be executed later.
