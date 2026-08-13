# AS7 notes

## 1. Native crash stacks — the sprint's premise was wrong (FIXED)

**Symptom.** Any VM assert printed a one-frame stack. The real thing, from a
deliberately corrupted method fingerprint:

```
Dumping native stack trace for thread 42ac
  [0x00007ff72fc96234] dart::Profiler::DumpStackTrace
  [0x00007ff72fc96234] dart::Profiler::DumpStackTrace
-- End of DumpStackTrace
```

Two lines, the same address twice: `Append(original_pc_)` followed by the
walker's first iteration, which then fails its step check and stops. Useless
for diagnosis — and we are about to go hunting the StackResource bug, which
needs stacks.

**What SPRINTS_ARM64.md said to do:** *"`COPY_FP_REGISTER` on arm64 currently
yields SP, not FP (patch hunk #2 takes the x64 fallback), so `DumpStackTrace`
walks one frame. Needs an `armasm64` helper to read x29."*

**That cannot work.** Measured, before writing any fix
(`probes/fp_probe.cpp`, `probes/fp_probe2.cpp`):

| probe | result |
|---|---|
| `_AddressOfReturnAddress()-8` vs `RtlCaptureContext().Fp` | **disagree by 56 bytes** |
| `[x29+0]` | a stack address |
| `[x29+1]` | `0x6937_7ff60d641c1c` — a real return address **smeared** with garbage in the top 16 bits |
| `RtlVirtualUnwind`'s reported `Fp` across frames #0–#2 | **unchanged** |
| `RtlCaptureStackBackTrace` on the same stack | walks it perfectly |

Windows unwinds from **`.pdata`/`.xdata`**, not from a frame-pointer chain. The
compiler may place the saved `{x29,x30}` pair anywhere in a frame, or omit it
entirely. `ProfilerNativeStackWalker`'s `[fp+0]=caller-fp / [fp+1]=return-addr`
walk therefore cannot follow C++ frames on this platform *whatever* value
`COPY_FP_REGISTER` produces — which is also precisely why upstream's x64 branch
has always just returned SP with the comment *"We don't have the asm equivalent
to get at the frame pointer on windows x64"*. Reading x29 correctly would have
changed nothing. An hour of probe work saved a day of assembler plumbing that
would not have worked.

**The fix** (`port-win/windart-port.patch`, `runtime/vm/profiler.cc`): ask the
OS. `DumpNativeStackTraceWindows()` seeds a `CONTEXT` — from
`RtlCaptureContext` for a self-dump, or from the caught `CONTEXT` the embedder
hands `Dart_DumpNativeStackTrace` — then loops
`RtlLookupFunctionEntry` + `RtlVirtualUnwind`, feeding each pc to the existing
`DumpStackFrame()`, which already symbolizes both Dart `Code` and native
symbols. `RtlVirtualUnwind` is used rather than the simpler
`RtlCaptureStackBackTrace` precisely because it can be seeded from a supplied
context. It stops cleanly when `RtlLookupFunctionEntry` returns NULL (JIT code
emits no `.pdata`) and says so rather than guessing.

Same trigger, after:

```
Dumping native stack trace for thread 4e34
  [0x00007ff7cba09ea4] dart::DumpNativeStackTraceWindows
  [0x00007ff7cba06f10] dart::Profiler::DumpStackTrace
  [0x00007ff7cba062cc] dart::Profiler::DumpStackTrace
  [0x00007ff7cb661634] dart::DynamicAssertionHelper::Fail
  [0x00007ff7cbbc15ec] dart::MethodRecognizer::InitializeState
  [0x00007ff7cb73623c] dart::Object::Init
  [0x00007ff7cb6ffe58] dart::Dart::InitializeIsolate
  [0x00007ff7cb5de468] dart::CreateIsolate
  [0x00007ff7cb5de634] Dart_CreateIsolate
  [0x00007ff7cb568c8c] dart::bin::main
  [0x00007ff7cb5698c4] main
  ... CRT startup ...
  [0x00007ffce6c45754] RtlUserThreadStart
-- End of DumpStackTrace
```

17 frames, symbolized, on **both** architectures — x64 was equally broken and
is equally fixed (verified with the same corrupted-fingerprint trigger). The
change is gated `HOST_OS_WINDOWS && (HOST_ARCH_X64 || HOST_ARCH_ARM64)`, so it
lives in the Windows-generic `windart-port.patch`, not the arm64 seam patch.

Notes:
- The top three frames are the dumper itself. Deliberately not skipped: a
  fixed skip count is wrong for the three entry points and would risk hiding a
  real frame. Debuggers show their own frames too.
- `Profiler::DumpStackTrace(void* context)` was a **no-op on Windows** before
  this (the `#else` branch); it now works.
- The profiler's *sampling* paths (profiler.cc ~1069, ~1119) are untouched.
  Different concern, and changing sampling behaviour is out of scope.
- `COPY_FP_REGISTER` is left as it is. It is now unused by the crash path, and
  the x64 fallback it takes is as correct as anything else available.

**Reproducing the trigger.** Corrupt a fingerprint in
`tree/runtime/vm/method_recognizer.h` (e.g. `0x6896fd05` → `0xdeadbeef`) and
build; `gen_snapshot` asserts during `Object::Init`. Restore afterwards — and
**touch the file** (`(Get-Item x).LastWriteTime = Get-Date`), because
`Move-Item` restores the original mtime and ninja will then skip the rebuild
and leave you with a poisoned object file.
