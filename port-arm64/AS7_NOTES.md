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

### Reproducing the trigger

Corrupt a fingerprint in
`tree/runtime/vm/method_recognizer.h` (e.g. `0x6896fd05` → `0xdeadbeef`) and
build; `gen_snapshot` asserts during `Object::Init`. Restore afterwards — and
**touch the file** (`(Get-Item x).LastWriteTime = Get-Date`), because
`Move-Item` restores the original mtime and ninja will then skip the rebuild
and leave you with a poisoned object file.

---

## 2. The StackResource inversion — FIXED (and it was never arm64's fault)

The bug carried in from AS3: with **background compilation** + an aggressive
optimisation threshold + genuinely-changed hot reloads, the VM aborted at
`allocation.cc:37 error: expected: top == this`, deterministically at round 7.
arm64 only; x64 from the same tree passed.

### What the working crash stacks showed immediately

With §1 landed, the first re-run named the whole path — the thing two sprints
of guessing had not:

```
  dart::LongJumpScope::~LongJumpScope
  `dart::CallSiteInliner::TryInlining'::`1'::dtor$0     <- SEH destructor funclet
  ... _CxxFrameHandler3 / RtlUnwindEx / local_unwind ...
  longjmp
  dart::LongJumpScope::Jump
  dart::CallSiteInliner::TryInlining
  dart::FlowGraphInliner::Inline
  dart::CompileParsedFunctionHelper::Compile
  dart::BackgroundCompiler::Run                         <- background thread
```

Two facts fall straight out. It is the **background compiler thread**, not the
mutator (the AS3 notes had inferred the mutator from a `LongJump::Jump` print).
And the assert fires *inside a `longjmp`-driven SEH unwind* — `_CxxFrameHandler3`
is running C++ destructor funclets.

### What was ruled out, with evidence

- **Cross-thread contamination.** `~StackResource` already carries a DEBUG
  `ASSERT(Thread::Current() == thread_)`, and it does not fire. One thread, one
  chain.
- **Accumulated stranded resources from earlier jumps.** A temporary probe in
  `Jump()` walked the live chain looking for its own `top_`: it was **always
  reachable at depth 0** — nothing to unwind, chain clean. So the corruption
  happens *during* the unwind, not before it. This also kills the AS3 working
  hypothesis (arm64's dual stack pointer making StackResource addresses
  non-monotonic): the addresses are fine at `Jump` time.

### Root cause: two unwinders for one chain

Dart manages the StackResource chain **itself** — `LongJumpScope::Jump` calls
`StackResource::UnwindAbove`, then `longjmp`. That design assumes `longjmp` is
a plain register restore, which is true everywhere Dart ships, because
**upstream Dart compiles with exceptions OFF**.

This port did not. `port-win/CMakeLists.txt` was inheriting **CMake's default
`/EHsc`** — never a decision, just a default nobody had cause to question (the
file even remarks on the consequence: *"Absent from Dart's own list only because
Dart compiled exceptions-OFF; our /EHsc (exceptions-on) posture surfaces it"*).
With C++ EH on, MSVC registers `_CxxFrameHandler3` for these frames, so
`longjmp` performs a **full SEH unwind that runs C++ destructors** — a second
unwinder, walking the same chain Dart is already walking by hand.

That is why neither previous setting worked, and why the notes recorded both as
failures. Keep the manual unwind and both run: double-destruct, and
`syntax_recover` aborts. Suppress it for MSVC (what the tree did) and the SEH
unwind becomes the only mechanism — but it reaches `~LongJumpScope` with the
chain already changed underneath it, which is the round-7 abort. There was no
correct answer available while both unwinders existed.

x64 survived only by luck of frame layout and funclet ordering; the hazard was
identical.

### The fix

Adopt upstream's posture. `port-win/CMakeLists.txt` strips `/EHsc` from the
CMake defaults and compiles `/EHs-c- /D_HAS_EXCEPTIONS=0`; `longjump.cc` drops
the MSVC carve-out so `StackResource::UnwindAbove` runs unconditionally, as on
POSIX. `longjmp` is now a register restore and Dart's manual unwind is the
single mechanism. Nothing in the port layer uses C++ exceptions (checked), so
turning them off costs nothing.

### Verification — both gates, both architectures

The two tests that could never pass together now do:

| test | arm64 | x64 |
|---|---|---|
| `reload_churn 40 400 --optimization_counter_threshold=100` | `CHURN_OK` | `CHURN_OK` |
| `reload_churn 300 400` (same threshold, the AS3 soak load) | `CHURN_OK`, 0 errors, 0 stale | — |
| `syntax_recover` | `SEH_OK`, 8/8 | `SEH_OK`, 8/8 |
| `reload_min` | `MIN_OK` | `MIN_OK` |
| `st_world_run` | green | green |

Also unchanged after the rebuild: `dartui.exe … selftest` exit 0 with 38 PNGs
(the D3D/COM GUI layer is now exceptions-off too), ST/Dart ratio mean 1.01x,
and cog-bench (arith 11.7, fib 165.4, sieve 3.8, alloc 113.2, richards 10.9,
deltablue 26.4).

**`--no_background_compilation` is no longer needed.** The AS3 workaround can be
retired.

### The lesson worth keeping

The bug was never in arm64 codegen, the dual stack pointer, or the i-cache — the
three things a porting engineer instinctively suspects. It was a **build flag we
never chose**, inherited from a tool default, quietly contradicting a design
assumption made by the code we were porting. Two sprints of inference pointed at
the CPU; ten minutes of a working stack trace pointed at the truth. Fix your
diagnostics first.
