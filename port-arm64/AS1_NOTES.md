# AS1 — Arch-parameterised build system; the full engine compiles (notes)

Sprint AS1 of `SPRINTS_ARM64.md`. Host = target: Snapdragon X (Oryon), MSVC
14.51 native arm64.

## What changed (owned files)

- **`port-win/extract.py`** — de-pinned: `SRC`/`DEST` now default to
  `<workroot>\sdk-1.24.3` / `<workroot>\tree` beside the repo clone
  (env overrides `WINDART_SDK_SRC` / `WINDART_TREE`); applies
  `port-arm64/windart-arm64.patch` after the two existing patches, with a
  `--dry-run` gate first so a reject fails loudly before any file is touched.
  All arm64 hunks are `#if`-guarded, so the same tree still builds x64
  byte-identically — one tree, two `build-<arch>` dirs.
- **`port-win/gen_sources.py`** — `--arch {x64,arm64}` selects which backend
  the drop-regex KEEPS. Sanity (vm_sources.gypi, arm64): 157 TUs, 12 `_arm64`,
  0 `_x64`, 0 `simulator_*`, `assembler_arm64.cc` present.
- **`port-win/CMakeLists.txt`** — `WINDART_ARCH` is **derived from
  `MSVC_CXX_ARCHITECTURE_ID`** (the toolchain in use), never guessed from the
  host; an explicit `-DWINDART_ARCH` may only *assert* it (mismatch = fatal).
  ARM64EC deliberately not matched (x64-compat ABI — wrong target for a JIT
  emitting real arm64). Per-arch defines: `TARGET_ARCH_ARM64` +
  `_ARM64_NO_EXTENDED_INTRINSICS` (the `arm64_neon.h` `mvn` macro, plan §2.6)
  vs `TARGET_ARCH_X64`. `malloc_hooks_(tcmalloc|jemalloc|${WINDART_ARCH})`
  filter. `TREE` → `WINDART_TREE` cache path, default `<workroot>/tree`.
- **`port-win/build.ps1`** — `-Arch arm64|x64` (default = host) selects
  `vcvarsarm64.bat`/`vcvars64.bat`; repo-relative paths; builds into
  `<workroot>\build-<arch>`; cmake/ninja addressed by FULL PATH (the
  VS-bundled copies) so nothing depends on what vcvars puts on PATH.
- **`port-win/dart_st/st_natives.cc:1359`** — the GCC `__asm__` AAPCS64 FFI
  trampoline gated `&& !defined(_MSC_VER)` (MSVC arm64 has no inline asm of
  any kind). No behaviour change: `ST_ffiCall`'s `_WIN32` branch already
  throws catchably, and the only call site sits inside the non-`_WIN32`
  branch. The real Win-arm64 trampoline is AS7 (armasm64 `.asm`; x18 = TEB).

## The burn-down (first full build, `-k 0`)

**591 build jobs; exactly ONE failing translation unit** (compiled twice, once
per engine variant):

```
vm\os_thread_win.cc(181): error C3861: '__readgsqword': identifier not found
```

`OSThread::GetCurrentStackBounds` reads the TIB's `StackBase`/`StackLimit`
through the **GS segment register** — pure x86-64; arm64 has no segment
registers (its TEB pointer lives in **x18**). Fix: under `_M_ARM64`, read the
same fields through `NtCurrentTeb()` (which winnt.h compiles to a read of
register 18) cast to `NT_TIB*` — the canonical portable idiom. The A0 probe
missed this file because it exercised the arch-conditional *#error* seams, not
the intrinsics; this is exactly the residue the sprint's `-k 0` sweep exists
to catch.

`windart-arm64.patch` is now **8 files / 20 hunks**, re-verified to dry-run
clean against pristine 1.24.3.

Everything else — both engine variants (~440 TUs each incl. the 11 arm64
backend TUs), `dart_builtin`, `dart_io`, `dart_win32` (Win32/D2D/D3D11/XAudio2
+ SQLite amalgamation), `dart_st` (the ST compiler driving arm64 constants for
the first time) — compiled with **no new warnings categories and zero errors**.
The plan's "Layer 2 is free" claim held on first contact.

## Stack-bounds note (why the fix is also *correct*, not just compiling)

`GetCurrentStackBounds` feeds `OSThread::stack_base_`, which the interpreter
uses for overflow checks. On Windows, `NT_TIB.StackLimit` is the **committed**
lower bound (moves down as the guard page commits), not the reserve limit —
same semantics the x64 `__readgsqword` path read, so behaviour matches x64
exactly. The deep-recursion probe in AS7 exercises this on purpose.
