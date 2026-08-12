# AS4 — dartui.exe: the IDE up on Oryon (notes)

Sprint AS4 of `SPRINTS_ARM64.md`. **Exit met 2026-08-12** — and the run carried
well past its own scope into AS5 territory (the D3D11 game pane, §3).

Command: `dartui.exe workspace.dart selftest`, run from `test\`. Exit code 0,
`SELFTEST: done`, **36 PNGs** captured to `<workRoot>\shots\`.

## 1. What works, natively, on arm64

**Boot.** `[windart] snapshot: booting from on-disk .bin (vm=905004 iso=266231)`
— the Stage-2 swap-without-relink path, on the arm64-tagged snapshot AS2 built.

**The view-server + materializer.** All 9 tabs materialize, snapshot and tear
down: Browser, Workspace, Editor, Find, App, Debug, VM, Docs, Help, Game.
Splitter drag (`SPLIT: dragged br_split ticket=293`), window resize with
relayout at three sizes, toolbar/menu dispatch, and history nav (back/home).
The `ui.remove`-drops-tickets regression holds:
`REVISIT: keypad widgets after leaving App = 0 (0 = destroyed, not hidden)`.

**The live class browser.** 16 libraries / 21 classes, `dart:io -> 88 classes`,
`File -> 0 vars, 32 methods`, instance/class side toggle
(`side=class -> 16 vars, 1 methods`), and **real on-disk SDK source** with
syntax highlighting — read through the de-pinned root
(`<workRoot>/tree/sdk/lib/...`), not mirror signatures.

**Do-It, both languages.**
```
DOIT:    (2 + 3) * 7 => 35
ST-DOIT: 25 sqrt     => 5.0
ST-DOIT: #(1 2 3) size => 3
ST-DOIT: st> 6*7     => 42
```
`LANG: bilingual language isolate up` — the Smalltalk front-end
(`st_flow_graph_builder` driving the **arm64** backend) is live, and
`ST-GAME galaxigans: imported 7 classes` proves the `.mst` loader works.

**Accept + morphing hot-reload — the capstone.**
```
ACCEPT: Counter reload="ok"   live Counter.n=21  inc()=7
ACCEPT: Counter reload="ok"   live Counter.n=21  inc()=11
REVERT: Counter reload="ok"   live Counter.n=21  inc()=7 older=2
ACCEPT REJECTED (syntax): Counter: line 2 pos 12: semicolon expected
```
The live instance **keeps its state across a class-shape change** and gains the
new behaviour; Revert steps back through accepted versions; the syntax gate
rejects uncompilable source without killing the isolate. `Counter.n=21`
persisted from earlier runs — the SQLite image at
`%USERPROFILE%\.windart\workspace.sqlite` survives restarts, as designed.

**The debugger.** Full session on arm64:
```
DBG: attached; breakpoint at debug_target.dart:15 -> id 1
DBG: PAUSED at breakpoint: factorial line 15
DBG: call stack: #0 factorial ... #1 main ...
DBG: frame locals: n=5
DBG: frame-eval  n * n  =>  25
DBG: step over -> stepped to factorial line 16; resuming
DBGTGT: factorial(5) = 120
```
Frame-scoped evaluation against a paused arm64 JIT frame is the demanding part
and it works.

## 2. Two repo bugs fixed (neither arm64-specific)

1. **13 dead `E:` path pins in `workspace.dart`** — SDK roots, `language.dart`,
   the ST world/galaxigans, and every PNG output path. Replaced with
   script-relative resolution derived from `Platform.script`:
   `scriptDir` / `repoRoot` / `workRoot` / `outDir` (+ `outPng(name)`), with
   `outDir` overridable via `$WINDART_OUT` and defaulting to
   `<workRoot>/shots`. Before the fix: `LANG: cannot stage language.dart` and
   every `SNAP: ... ERR:cannot open PNG file for write`.
2. **The selftest's App step drove a null `calc`.** `calc` is declared
   (`Calculator calc;`) but **never assigned** anywhere in the file — the App
   pane's keypad is a *Smalltalk* app materialised over the C4 `appui` bridge
   (`buildApp` → `ask('appbuild')`), so it only exists after
   `ui apprun <StClass>`. The selftest called `calc.press(...)`
   unconditionally, threw `NoSuchMethodError` on null and **killed the UI
   isolate**, aborting every step after it — including the game-pane captures.
   Now guarded: drive the keypad when an app is live, always snapshot the tab.

   **Verified pre-existing, not a port defect:** the x64 build from the same
   tree fails identically (`APP: keypad built, 0 key widgets` →
   `press on null`). This is the third time the x64 control has paid for
   itself.

## 3. Bonus: the game pane already runs (AS5 preview)

The steps unlocked by fix #2 went straight into the D3D11 engine, on Adreno:
```
GP_SFX: define slot=0 preset=jump (audio on)   <- XAudio2 live
GAME: coindash frames=83 opened=true
GAME: gpSnap OK  gpSnapPresent OK
GAME: tiletest frames=98 ... gpSnap OK  present OK
GAME: left Game tab -> stopGame done=true
```
`tab_game.png` shows **COIN DASH rendering live** — starfield gradient,
parallax ground, sprites and the seven-segment text overlay, composited into
the IDE. The indexed pane, sprite layer, tile layer, text overlay, offscreen
readback *and* live present all work on Qualcomm's D3D11 driver, first try.
AS5's remaining work is therefore the demo battery, Invaders/Brickout, the
WARP-reference diffing — and the unified-memory rework
(`GPU_UMA_DESIGN.md`), which is now the main event rather than a risk.

## 4. Follow-up work — done in the same session

**All 43 remaining `E:` pins fixed** across 26 files in `test/` and `tcl/`.
Two shared helpers now carry the convention:

- `test/wsout.dart` — `scriptDir` / `repoRoot` / `workRoot` / `outDir`,
  `outPng(name)`, and `sibling(relative)`. Imported by 10 drivers.
- `tcl/dartui.tcl` — `outdir` / `outpng` procs (20 call sites). Every test
  already sourced this file, so nothing else changed.

Output defaults to `<workRoot>/shots`, overridable with `$WINDART_OUT`; the ST
world corpus is selected by `$WINDART_ST_WORLD` in both `workspace.dart` and
`tcl/test_c2_browser.tcl`. Applied by an 8-group workflow where each group was
migrated by one agent and then **independently re-verified by another**; the
verifiers caught the real trap — several drivers declared a *local* named
`outPng` that would have shadowed the imported function.

**A second, deeper location bug the verifiers surfaced.** Seven
`Isolate.spawnUri(Uri.parse('demos/$game.dart'))` sites — in `demo_runner`,
`game_live`, `game_runner`, `gp_runner`, `debug_probe`, and **twice inside
`workspace.dart`** — were CWD-relative. They only ever worked because every
invocation happened to `cd` into `test/` first. Same class of defect as the
path pins, and it would have broken AS5's demo battery from any other
directory. Fixed with `sibling()` / `Platform.script.resolve()`; note
`Uri.parse` on an absolute Windows path is *also* wrong (it reads the drive
letter as a URI scheme), which is why this resolves against `Platform.script`
rather than building a string. `c0_seam.dart` was already correct
(`scratch.uri` is absolute).

**Verified against the actual failure mode** — the full selftest run from
`C:\` rather than `test\`:

```
CWD = C:\   (deliberately NOT test/)
ST-WORLD: 179 Smalltalk classes browsable
DBG: PAUSED -> frame-eval n * n => 25 -> factorial(5) = 120
GAME: coindash frames=85 / tiletest frames=99
SELFTEST: done      exit 0
```

**The ST world turned out to be available and to work** — see
`ST_WORLD_FINDINGS.md`. 179 classes browsable; the class library needs no
porting; 19 Cocoa/POSIX-bound classes across 26 files do.

## 5. Still open

- The App pane cannot be exercised headlessly until the selftest issues
  `ui apprun` against an ST class that builds through the Windows widget
  protocol — one of the 19 classes needing the `Mac-ST → Windows-ST` re-point.
- `tclsh` is still not installed, so the TCL battery (AS6) has not been run
  even though its paths are now correct.
