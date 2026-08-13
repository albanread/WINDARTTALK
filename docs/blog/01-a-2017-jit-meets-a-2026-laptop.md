# A 2017 JIT meets a 2026 laptop

*Porting the Dart 1.24.3 VM — and the Smalltalk riding inside it — to
Windows-on-ARM64, on the machine it targets.*

The development machine for this port is also the target: a Snapdragon X
laptop, eight Oryon cores, Windows 11 arm64. No cross-compiling, no device
farm. You build it, you run it, and if it is slow you feel it personally.

The candidate for porting was WINDARTTALK: a **Dart 1.24.3** JIT VM (the
last of the V1 line, December 2017) carrying a Smalltalk front-end, a
windowed IDE, and a D3D11 game pane — already running on Windows x64. The
useful surprise, which shaped the whole job: the VM *already had* an arm64
backend. Google shipped one in 2017 for Android phones. What the code had
never met was **MSVC targeting arm64** — a compiler that barely existed
when the VM was written. So the port was never going to be "write a code
generator"; it was going to be introductions between an old VM and a new
toolchain. Claude did the legwork throughout — the extraction scripts, the
build plumbing, the patches — with me pointing and occasionally objecting.

## The keystone is one line

Platform detection in `platform/globals.h` tested `__aarch64__`. MSVC does
not define `__aarch64__`; it defines `_M_ARM64`. The fix:

```cpp
#elif defined(__aarch64__) || defined(_M_ARM64)
#define HOST_ARCH_ARM64 1
```

Hardly a triumph of engineering. What earns it the word *keystone* is the
failure mode without it: the build does not break. It configures politely,
selects **`USING_SIMULATOR`**, and produces a `dart.exe` that runs your
programs on an ARM64 *interpreter of ARM64 instructions* — simulating the
machine it is already running on. Everything works. Everything is slow. If
you never check for the tell, you could ship it. The failures to worry
about in a port are not the crashes; they are the successes.

## The compiler objects, briefly

With the keystone in, 591 translation units compile, minus a short list of
skirmishes:

- **`arm64_neon.h` defines a macro called `mvn`.** The Dart assembler has a
  method called `mvn`. The preprocessor is unmoved by namespaces.
  `_ARM64_NO_EXTENDED_INTRINSICS` switches the macro off.
- **`__readgsqword` does not exist** — reading the TEB through the x86 GS
  segment is an x86 habit. `NtCurrentTeb()` is the portable spelling.
- **`atomic_win.h` was x86-only in nine places** — each gate needed an
  `|| defined(_M_ARM64)`; the Interlocked family maps over without fuss.
- **There is no CPUID on ARM.** The processor name lives in the registry
  (`ProcessorNameString`). Ours reports a Snapdragon X `X126100`.

That is most of the compile-time story. The runtime story is shorter, and
less forgiving.

## The instruction cache does not forgive

On x86, if you write machine code to memory and jump to it, it runs — the
instruction cache snoops the data cache, and decades of self-modifying
code lean on that. ARM64 makes no such promise: the i-cache is **not
coherent** with the d-cache. A JIT that writes code and jumps to it
without ceremony executes whatever stale bytes the i-cache happens to
hold. Sometimes that is the old method. Eventually it is worse.

The fix is one call — `FlushInstructionCache` after every code write in
`cpu_arm64.cc` — but trusting it wanted more than a smoke test, because
this VM does not JIT once and settle down. The Smalltalk IDE hot-reloads:
edit a class, Accept, and methods recompile into memory the old code just
vacated — a purpose-built stale-cache stress machine. So Claude tortured
it: **500 reload rounds, 400 calls per round**, every result compared.
Zero stale reads. After that we stopped worrying about it, which is the
most a cache flush can hope for.

## Two stack pointers, one register file

The oddest arm64-ism in the VM: generated Dart code keeps its own stack
pointer in a general register (**R15**), separate from the hardware `SP`
(**R31**, the CSP). ARM64 requires the hardware SP to be 16-byte aligned at
every access through it; Dart's generated code prefers a cheaper contract.
So the VM maintains both, and on frame entry parks the hardware SP safely
below the Dart stack:

```
CSP = (SP - 4096) & ~15;
```

— far enough down that exception delivery cannot land on live Dart frames,
aligned because the architecture insists. None of this needed changing for
Windows. It is in this article because you cannot debug what you do not
know about, and the dual-pointer arrangement turns up twice later in the
series: as a suspect in an open bug, and as a measurable per-call cost
against the x64 backend.

## Where it landed

The VM-core port is **8 files and 20 hunks**. The 2017 JIT runs natively
on the 2026 laptop, the optimizing tier demonstrably kicks in, the reload
torture test passes, and the PE header says `0xAA64` where it used to say
`0x8664`. Not a large diff, for which the 2017 Android team deserves most
of the credit — the hard part of "Dart on Windows-on-ARM" was done years
ago by people targeting phones. What remained was mostly spelling:
`_M_ARM64` where the code said `__aarch64__`, `NtCurrentTeb()` where it
said `__readgsqword`, and one cache flush where x86 had let everyone be
lazy.

*Next: what the Snapdragon's unified memory actually buys a software
renderer — measured, including one result we'd rather have not needed.*
