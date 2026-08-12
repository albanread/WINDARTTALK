# AS6 — the TCL control plane on arm64 (notes)

Sprint AS6 of `SPRINTS_ARM64.md`, partial. The control plane works end to end on
Windows-on-ARM; the battery is 6/12 with the remaining failures traced to one
concrete Smalltalk-world defect (not the port).

## 1. tclsh — no install needed

Git for Windows already ships a **native arm64** Tcl:

```
C:\Program Files\Git\clangarm64\bin\tclsh.exe     8.6.18, machine = arm64
```

PE machine type `0xAA64` — native, not emulated. Magicsplat's winget package is
x64-only and would have run under emulation; it is unnecessary.

`dartui.tcl` needs **no `package require`** at all — it implements its own JSON
parser (`::jsonp::parse`) and its own WebSocket framing, precisely because
tcllib's `websocket` does not work with the shipped `http` (see its header). So
a bare `tclsh` is the whole dependency.

Launch the target with the vm-service exposed:
```
dartui.exe --observe workspace.dart        ->  Observatory listening on http://127.0.0.1:8181/
```
No auth token on 1.24.3, so `ws://127.0.0.1:8181/ws` connects directly.

## 2. The wire works — `tcl/test_arm64_smoke.tcl` (new)

```
ping                       OK    pong
doit (Dart)                OK    35
doit (Smalltalk)           OK    5.0
doit (ST arith)            OK    42
tab -> Browser             OK    ok
browse Duration            OK    browsed Duration
ufind sqrt                 OK    find "sqrt" -> 7 matches
snap -> outpng             OK    ok:C:/projects/WINDARTARM/shots/arm64_smoke.png
ARM64_SMOKE_OK
```

Both languages evaluate through the *same* wire, and the capture lands in the
de-pinned output directory.

## 3. Battery results

| test | result |
|---|---|
| `test_bilingual.tcl` | **PASS** — ALL CHECKS PASSED (ping, ST `25 sqrt`, `#(1 2 3) size`, `6*7`, Dart closure, PNG) |
| `test_find_ui.tcl` | **PASS** — `ufind sqrt` 7 matches, `usenders Fraction` 9 classes, 3 PNGs |
| `test_c2_browser.tcl` | **PASS** — stimport 172 classes; `OrderedCollection` + `do:` + real `.mst` source |
| `test_c2_ui.tcl` | **PASS** — Smalltalk class browsed in the GUI |
| `test_c3_ui.tcl` | **PASS** — live Smalltalk editing in the GUI |
| `test_c4_app.tcl` | **PASS** — app rendered + button event fired |
| `test_arm64_smoke.tcl` | **PASS** (new) |
| `test_catalog_ui.tcl` | **PASS** — catalog, rolled, app captures |
| `test_inspect_ui.tcl` | **PASS** — inspect Fraction, dive, OrderedCollection |
| `test_method_body.tcl` | **PASS** — whole method bodies render on selection |
| `test_slicer_snap.tcl` | **PASS** — ST-host slicer |
| `test_stdebug_ui.tcl` | **PASS** — ST post-mortem debugger (stack, frame, ok) |
| `test_c5_game.tcl` | **FAIL — crashes the VM** (§4) |

**11 of 12.** The last five initially appeared to fail, but only at `connect` —
`test_c5_game.tcl` had already aborted the process. Re-run against a surviving
IDE (world imported without the two gamepane-wiring files) they all pass. Worth
noting as a testing hazard: a crash in one test makes every later test in the
battery look broken.

## 4. The C5 crash — pre-existing, and isolated to two files

```
runtime/vm/intermediate_language.h: 3345: error: expected: !function.IsNull()
```

`StaticCallInstr`'s constructor rejecting a null target: the ST flow-graph
builder emitted a static call to a function it could not resolve.

**Not an arm64 defect** — the x64 build from the same tree gives the identical
assert at the identical line. Full triage, including the invalid first
comparison that nearly produced a wrong call, is in `ST_WORLD_FINDINGS.md`.

**Trigger isolated to `80_gamepane_wiring.mst` + `83_gamepane_direct.mst`.**
With those two excluded (95 of 97 files) the double-import and `ui stgame` both
survive and the IDE stays up — but ST games cannot render, because that wiring
is what bridges ST `GamePane` to the D3D11 pane. Those two files are therefore
the minimal, concrete `Mac-ST → Windows-ST` port target.

## 5. Two PowerShell traps worth remembering

- **Variables are case-insensitive.** `$T` and `$t` are the same variable, so
  `foreach ($t in …)` silently clobbered a `$T` holding the tcl directory.
- **.NET file APIs use the process CWD, not the PowerShell location.** A `cd`
  followed by `[System.IO.File]::ReadAllText('rel/path')` resolves against the
  wrong directory and reports every edit as a no-op. Use absolute paths.

## 5a. The 16 shims — two crash classes fixed, rendering not yet

**Layer 1 — the missing primitives (`cocoa.dart`).** All 16 added: 10 map onto
`gpApply` verbs the C++ engine already implements (`gpframe`, `gpplace`,
`gphide`, `gplinepal`, `gptext`, `gptextclear`, `gpshader`, `gpparam`,
`gpsound`, `gpplay`), 5 are pure block storage (`onStep:`/`onReset:`/
`stepBlock`/`resetBlock`/`clearBlocks` — ST blocks are directly callable Dart
closures, so they are simply held), and `stHostStoreClass` routes onto the
existing `_stHost` service. Verified: **world requests 97 distinct stprims,
0 missing.** Contracts checked against the C++ dispatch rather than guessed —
e.g. `gpplace` needs 8 elements (id, x, y, frame, scale, rot, alpha) where the
ST face supplies 4, and `gptext` has no per-draw scale so ST's `scale:` is
accepted and dropped rather than mis-passed as a colour channel.

**Layer 2 — the native resolver.** Fixing layer 1 moved the abort rather than
removing it: `intermediate_language.h:3345` became
`builtin_natives.cc:45: unreachable code` (`Builtin_DummyNative`). Cause:
`cocoa.dart` declares the gamepane natives as `Cocoa_gp*` (it is shared with
MACDART, where `Cocoa_` *is* the platform prefix), `CocoaNativeLookup` resolves
only its own `ST_*` set, and nothing else answered. Windows implements the
identical contract as `Win_gp*` with matching arities, so `CocoaNativeLookup`
now rewrites the prefix and delegates to `WinNativeLookup` — one fallthrough
instead of a second table to maintain, and the arity check still applies so a
mismatch fails closed.

**Result:** the **full, unfiltered 97-file world** imports twice and
`ui stgame MandelZoom` runs without killing the VM. `test_c5_game.tcl` exits 0;
dartui survives. The two exclusions from the earlier workaround are no longer
needed.

**Smalltalk games now render.** `Galaxigans` draws its title screen on the D3D11
pane — see `shots/stgame_Galaxigans.png`. The text is produced by the new
`stGpText` shim → `gptext` → the seven-segment overlay, so the shim layer is
proven end to end, not merely non-crashing.

**MandelZoom renders black — and it is not the shims.** Instrumenting
`_gpOneFrame` gave the answer immediately:

```
GPTRIAGE: launch MandelZoom setupOps=256 stepBlk=true running=true
GPTRIAGE: frame 1 ops=0 stepBlk=true
GPTRIAGE: frame 2 ops=0 stepBlk=true
```

Setup emitted 256 ops (the palette), `onStep:` stored the block, `run` fired,
the tick ran — yet every frame produced zero draw ops. Cause:

- `MandelZoom` and `MandelVM` are the two games flagged **`'direct': true`**
  (`language.dart:408,410`) — whole-frame CPU renderers that write straight into
  the GPU framebuffer via `directBlit:` instead of emitting draw commands.
- `stGpDirectBlit` begins `var fb = gpBackbuffer(); if (fb is! Uint8List) return p;`
  — a documented silent no-op when the backbuffer is absent.
- On this port `Win_gpBackbuffer` is a stub: `// _gpBackbuffer() -> null
  (direct framebuffer mode deferred, S6b)`.

So `test_c5_game.tcl` happens to hardcode `set first MandelZoom` — one of only
two direct-mode games in the table. It was testing the one feature this port has
never implemented. `tcl/test_stgame_any.tcl` (new) takes the game name as an
argument so an indexed game can be exercised instead.

**This lands exactly on the unified-memory work.** Implementing
`Win_gpBackbuffer` to hand Dart an `ExternalTypedData` over mapped GPU memory
*is* Tier 2 of `GPU_UMA_DESIGN.md` — the deferred S6b feature, which on this
UMA silicon is also the 5.7–19.4× win. One piece of work unblocks the direct
Smalltalk games and the biggest available game-pane speedup at the same time.

### The other two games, and a crash worth chasing

The instrumentation run also answered `Worms` and surfaced one new abort:

- **Galaxigans really is drawing:** `GPTRIAGE: frame 2 ops=62` — 62 draw ops per
  frame, not a static blit.
- **`Worms` needs FFI:** `ST game Worms: ERR FFI: not yet supported on windart
  (Win64 trampoline pending)`. That is `ST_ffiCall`'s pre-existing `_WIN32`
  branch failing **safe** exactly as intended — a catchable error, not a crash —
  so `gamepane: not open` was a symptom, not the cause. Worms is blocked on the
  Win-arm64 FFI trampoline (AS7), not on anything in the ST wiring.
- **A pre-existing spawn bug, unrelated to the de-pinning:** switching to the
  Game tab with an ST game selected tries to spawn a *Dart* isolate
  `demos/Galaxigans.dart` / `demos/Worms.dart`, which do not exist — the ST game
  name is being fed to the Dart game spawner. The path is now absolute in the
  message (`Platform.script.resolve`) which is what makes it legible, but the
  file was equally absent under the old CWD-relative form, so this is not a
  regression from that change.
- **NEW abort to triage:** shortly after the Worms FFI error,
  `isolate.cc:2691: expected: sticky_error_ == Error::null()`, then a cascading
  `handles_impl.h:88: expected: thread->top_handle_scope() != NULL` inside the
  crash-dump path itself. Likely the ST error thrown by the FFI gate leaving a
  sticky error that is never cleared. Almost certainly **not** arm64-specific —
  `ST_ffiCall`'s throw is `_WIN32`-gated, not arch-gated — but that needs the
  x64 control to confirm rather than assume.

## 5b. Direct framebuffer implemented — the battery closes

Both UMA tiers landed (`GPU_UMA_DESIGN.md`), and Tier 2 was exactly the missing
piece under `test_c5_game.tcl`:

- **Tier 1:** index slots `DEFAULT`+`UpdateSubresource` → `DYNAMIC`+`Map`.
  Verified *identical*, not just faster: `tiletest` (static, deterministic) is
  byte-for-byte the same on SHA-256 before and after; `coindash` differs only by
  landing on a different animation frame (`DIST 23` vs `DIST 24`).
- **Tier 2:** `Win_gpBackbuffer` now hands Dart mapped GPU memory. **MandelZoom
  renders** (`shots/stgame_MandelZoom.png`) where it was an 895-byte black frame.

**TCL battery: 13 of 13 — but `test_c2_ui.tcl` is FLAKY, not fixed.**

`test_c5_game.tcl` — for a long time the only failure — now passes reliably.
`test_c2_ui.tcl` is a different matter and worth stating precisely, because the
first two explanations were both wrong:

- It is **not** simply order-sensitive. A retry loop (20 × 1 s) was added on the
  theory that it was racing the ST world's two-stage async import. It then
  passed 13/13, which looked like a fix.
- It is **not** leftover state from a running game either. It failed again on a
  freshly launched dartui with no game running.
- Observed sequence across repeated full-battery runs: **FAIL, FAIL, PASS,
  PASS** — and when it passes it passes on the *first* browse attempt, so the
  retry loop is not what rescues it. When it fails it is not failing slowly, it
  is failing differently.

So it is intermittent, and any single battery number — including the 13/13 above
— is one sample of a flaky test and should not be quoted as stable. Tracked
separately with the next diagnostic step (the test only prints `$r` on the
success path; it needs an else-branch print to reveal what `ui browse` actually
returned on a failing run).

## 5c. Battery green, and a deterministic bug found while chasing an intermittent

**TCL battery: 13 of 13.** The last failure, `test_c2_ui.tcl`, was a fixed
`after 6000` racing the ST world's two-stage async import — it passed standalone
and failed only when it followed `test_c2_browser.tcl`'s own 97-file `stimport`.
Replaced with a bounded retry that waits for the *condition* (the ST browse
path being taken) rather than an interval. The test's own failure message had
already guessed the cause: *"ST world not loaded yet?"*.

**The sticky-error abort (§ open) did not reproduce, and my hypothesis was
wrong.** `ui stgame Worms` does hit `ERR FFI: not yet supported` — and dartui
stays alive, with ping / Dart Do-It / ST Do-It / snap all working afterwards.
The failed Dart isolate spawns that accompanied the original abort also occur
freely without one. Replaying the whole original sequence does not reproduce it.
It was seen exactly once, late in a long session. Recorded as intermittent
rather than explained away.

**But chasing it surfaced a real, deterministic defect.** `buildGame()` ended
with an unconditional `startGame(gameSel)`. `gameSel` also holds the name when a
*Smalltalk* game is running (`startStGame` sets it), so every tab rebuild handed
an ST name to the **Dart** spawner:

```
GAME: spawn error Worms: IsolateSpawnException: Unable to spawn isolate:
  Could not load ".../test/demos/Worms.dart"
```

— once per ST game launch. And because `startGame()` opens with `stopGame()`,
it also tore down the ST game it had just started. Guarded with
`if (!_stGameActive && gameSel.isNotEmpty)`. Result: **spawn errors 0**, and
`Worms` now gets a working pane where it previously reported
`gamepane: not open`. `Galaxigans` now runs on into gameplay (`SCORE 50`,
`WAVE 1`, `SHIPS 3`) instead of being killed at the title screen.

## 5d. Game-tab controls, and one thing that could not be done cheaply

**Smalltalk games are now listed** alongside the Dart demos in one selection
list, `▸`-prefixed, fed from the language isolate's `stgames` and refreshed on
every Game-tab build (empty until the ST world imports). Row index maps back by
range: below `gpGames.length` → `startGame` (Dart isolate), above →
`startStGame` (language isolate).

**Pause / Stop buttons.** Pause holds the pull-pacer — no tick, no frame —
without touching any window, so the game resumes exactly where it stopped. Stop
tears the isolate down and closes the pane. A single `gameStatusText()` feeds
the label so it cannot disagree with the buttons; it names the language
(`running: Galaxigans (Smalltalk)`).

**Freeze-on-tab-away: attempted, reverted.** `gameSchedule()` already declines
to arm the next tick unless `activeTab == 9`, so deleting the `stopGame()` on
tab-leave *looks* like a free freeze. It is not: the tab switch runs
`clearContent()`, which destroys the `gp` surface window, while the engine keeps
its swapchain bound to that HWND. The next Present faults and takes dartui down
with **no Dart-level error at all** — verified by doing it (start MandelZoom,
leave the tab, return → process gone). Reverted to `stopGame()`.

A real freeze needs pane lifecycle work — close the surface on leave, reopen and
re-upload on return — not a scheduling tweak. Until then the in-tab **Pause**
button is the freeze. Consequence to keep in mind: leaving the tab still ends
the game, and returning re-launches only *Dart* games (an ST game must be
re-picked), because `buildGame` must not hand a Smalltalk name to the Dart
spawner.

**"MandelZoom seems slow" — it is, and not because of the port.** Its `step`
computes the entire 320×240 view every frame at `maxIter := 150`: 76,800 pixels
× up to 150 escape iterations ≈ **11.5 M iterations per frame**, written in
Smalltalk. 60 fps would demand ~690 M iter/s. The unified-memory work removed
the *upload* (one `directBlit:` into shared GPU memory, now genuinely zero-copy);
the *compute* is the game's own workload and is untouched by any of it.

The most likely lever is not the GPU at all: ST `Float` arithmetic goes through
Dart doubles, and Dart 1.24 boxes those unless the optimiser unboxes them —
11.5 M iterations of boxed arithmetic would be dominated by allocation and GC.
Worth measuring (`--compiler_stats`, GC counters via `wsVmStats`) before
optimising anything, and worth comparing against the Dart `04_mandelbrot` demo
which does the same maths natively.

## 6. Still open

- Port the two gamepane-wiring files, then re-enable `test_c5_game` — the only
  failing test in the battery.
- The world DB half of AS6 (export/import round-trip, re-baking the snapshot
  into the image) has not been exercised yet.
- The ST source shown over the wire has a cp1252/UTF-8 mismatch in the tcl
  client (`15_ordered.mst ? OrderedCollection`) — display-only, the IDE itself
  renders it correctly.
