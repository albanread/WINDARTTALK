# A 2017 JIT meets a 2026 laptop

*Porting the Dart 1.24.3 VM — and the live Smalltalk riding inside it — to
Windows-on-ARM64, on a machine that is both the workbench and the target.*

There is a particular pleasure in porting software to the machine you are
typing on. No cross-compile, no device farm, no "works in the emulator."
The dev box is a Snapdragon X laptop — eight Oryon cores, Windows 11 arm64
— and the goal was to get WINDARTTALK running on it natively: a Dart 1.24.3
JIT VM (the last of the V1 line) that carries a Smalltalk front-end, a
windowed IDE, and a D3D11 game pane.

Here is the thing that made this port interesting rather than routine: the
VM *had* an arm64 backend. Google shipped one in 2017 for Android phones.
What the code had never met was **MSVC targeting arm64** — a compiler that
did not exist as a serious target when this VM was written. Every
architecture test, every intrinsic, every piece of platform glue assumed
that "ARM64" implied "GCC or Clang."

## The keystone is one line

Platform detection in `platform/globals.h` looked for `__aarch64__`. MSVC
does not define `__aarch64__`; it defines `_M_ARM64`. The fix is the least
impressive diff of the whole port:

```cpp
#elif defined(__aarch64__) || defined(_M_ARM64)
#define HOST_ARCH_ARM64 1
```

What makes it the keystone is the *failure mode without it*. The build does
not break. It configures cheerfully, selects `USING_SIMULATOR`, and produces
a dart.exe that runs your programs on an ARM64 **interpreter of ARM64
instructions** — a simulator of the machine it is already running on.
Everything works. Everything is slow. If you never check for the tell, you
can ship it. The scariest failure mode in porting is not the crash; it is
the success.

## The compiler fights back, briefly

With the keystone in, 591 translation units compile — minus a handful of
skirmishes worth recording:

- **`arm64_neon.h` defines a macro called `mvn`.** The Dart assembler has a
  method called `mvn`. The preprocessor does not care about your namespaces.
  `_ARM64_NO_EXTENDED_INTRINSICS` turns the macro off.
- **`__readgsqword` does not exist.** The thread-local lookup read the TEB
  through the x86 GS segment register. ARM64 Windows keeps the TEB
  elsewhere; `NtCurrentTeb()` is the portable spelling and the compiler
  intrinsic does the right thing per-arch.
- **`atomic_win.h` was x86-only in nine places** — each `#if defined(_M_X64)`
  gate needed an `|| defined(_M_ARM64)`, and the Interlocked family maps
  cleanly.
- **CPU identification** read CPUID. There is no CPUID on ARM; the processor
  name lives in the registry (`ProcessorNameString`), which is where we now
  get it. Ours reports a Snapdragon X `X126100`.

That is nearly the whole compile-time story. The runtime story is shorter
and sharper.

## The instruction cache does not forgive

On x86, if you write machine code to memory and jump to it, it runs. The
instruction cache snoops the data cache; decades of self-modifying code
depend on it. ARM64 makes no such promise: the i-cache is **not coherent**
with the d-cache, and a JIT that writes code and jumps to it without
ceremony will execute *whatever stale bytes the i-cache happens to hold* —
sometimes the old method, sometimes garbage, always eventually.

The fix is one call — `FlushInstructionCache` after every code write in
`cpu_arm64.cc` — but trusting it needed more than a smoke test, because
this VM does not just JIT once. The Smalltalk IDE hot-reloads: edit a class,
Accept, and the VM recompiles methods *into memory the old code just
vacated*. That is a stale-cache stress machine. So we tortured it: 500
reload rounds, 400 calls per round, comparing every result. Zero stale
reads. That number is what let the rest of the project proceed on top of
the JIT without a background fear.

## Two stack pointers, one register file

The strangest arm64-ism in the VM: Dart code keeps its own stack pointer in
a general register (R15), separate from the hardware `SP` (R31, the CSP).
Why? ARM64 requires the hardware SP to be 16-byte aligned *at every memory
access through it*, and generated Dart code wants a cheaper contract. So
the VM maintains both, and on every frame entry the hardware SP is parked
safely below the Dart SP:

```
CSP = (SP - 4096) & ~15;
```

— far enough down that signal/exception delivery (which uses CSP) cannot
smash live Dart frames, aligned because the architecture insists. None of
this needed changing for Windows, but you cannot debug what you do not
know, and the dual-pointer arrangement turns up later in this series both
as a suspect in an open bug and as a measurable cost against the x64
backend.

## The punchline

The whole VM-core port is **8 files and 20 hunks**. A 2017 JIT runs
natively on a 2026 laptop, JITs real workloads (the optimizing tier
demonstrably kicks in), survives a hot-reload torture test, and the PE
header says `0xAA64` where it used to say `0x8664`.

The lesson we would pass on: when a port looks terrifying, check what
already exists. The hard part of "Dart on Windows-on-ARM" was done in 2017
by people targeting Android phones. What remained was the meeting of two
worlds that had simply never been introduced — an old VM and a new
compiler — and the bulk of *that* was spelling: `_M_ARM64` where the code
said `__aarch64__`, `NtCurrentTeb()` where it said `__readgsqword`, and one
crucial cache flush where x86 had let everyone be lazy.

*Next in the series: what the Snapdragon's unified memory actually buys a
software renderer — measured, including one negative result.*
