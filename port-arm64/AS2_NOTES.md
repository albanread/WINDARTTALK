# AS2 — dart.exe JITs on Oryon (notes)

Sprint AS2 of `SPRINTS_ARM64.md`. **Exit met 2026-08-12**, same day as AS1 —
the two sprints together took one build burn-down cycle.

## The milestone

```
> build-arm64\dart.exe hello.dart
hello, windart
sum 1..100 = 5050
```

Native **ARM64** PE binaries (verified machine type `0xAA64` in the PE
header): `dart.exe`, `dartui.exe`, `dart_bootstrap.exe` (~26.5 MB each,
Debug), `gen_snapshot.exe`.

## What the full build already proved before hello ran

`ninja` exit 0 includes the snapshot pipeline: **`gen_snapshot.exe` executed
on this Snapdragon** and compiled the entire core library from source inside a
nosnapshot VM, emitting the arm64-tagged core snapshot
(`vm_isolate_snapshot.bin` 905,004 B / `isolate_snapshot.bin` 266,231 B).
That is itself a full VM run — parser, compiler, GC — before `dart.exe` ever
started. Per plan §2.5 these snapshots carry the `" arm64"` features tag; the
stale x64 story is moot on this box (fresh tree, fresh image).

## Tier-up proof (`test\jit_tierup.dart`)

```
> dart.exe --compiler_stats test\jit_tierup.dart
fib(20) x200 -> 1353000
==== Compiled code stats:
Functions compiled:      350
 optimized:              1
Code size:               429 KB
Instr size:              236 KB
```

`optimized: 1` is the deep result: the **optimizing** arm64 backend recompiled
`fib`, `code_patcher_arm64` rewired the call sites in place, and — because the
program still computed 1,353,000 correctly afterwards — the
`FlushInstructionCache` hunk demonstrably published the patched code to the
i-cache. This exercises self-modifying arm64 code under Windows, the
capability the whole port hinges on (plan §1.2). All runs are the `Debug`
build, so `dart.cc:110-118`'s `CHECK_OFFSET` layout self-tests passed at every
VM start as a side effect.

## Bonus AS3-preview smokes (all green)

- `isolate_test.dart` — `Isolate.spawn` square + round-trip echo → `ISOLATE_TEST_OK`.
- `mirror_test.dart` — 337 classes reflected.
- `io_test.dart` — Platform/File/Directory/stdio → `IO_TEST_OK`
  (after de-pinning its hardcoded `e:/windart/...` probe paths to
  script-relative ones — a repo bug predating the port; 8 processors reported,
  which is the Oryon's core count).

AS3 proper still owes the 500× reload-churn i-cache probe and the
syntax-error/longjmp check.
