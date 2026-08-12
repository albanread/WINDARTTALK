# The Smalltalk world on Windows ARM64 — what actually ports

Measured 2026-08-12 on the Snapdragon X (Oryon) build. Written because the
working assumption was that the Mac world "won't work here"; the truth is
more useful than either yes or no.

## Where the world lives

Not in this repo. `.gitignore` says so explicitly — *"the MACDART reference
clone (its own repo; obtain from github separately)"*. Verified:

- **WINDARTTALK** tracks exactly **two** `.mst` files (`demos/galaxigans.mst`,
  `tcl/rolling_hello.mst`), one branch, and no `.mst` was ever deleted from its
  51-commit history. The world was never here.
- **MACDARTV1** `main` has **zero** `.mst`. The corpus is on the
  **`dartui-workspace`** branch: `macdart/st/world` (97 files), plus
  `st/world/bench` (12), `st/test/features` (13), `st/examples` (3).

Fetch just the world:

```bash
git clone --filter=blob:none --no-checkout --branch dartui-workspace https://github.com/albanread/MACDARTV1.git
```
then `sparse-checkout set macdart/st`.

## What works — measured, not assumed

**The whole corpus loads.** `dart.exe st_world_run.dart <world>`:

```
world booted (97 files)
--- exercising the loaded library ---
OrderedColl    6          Fraction       5/6
Dictionary     30         WriteStream    hello world
Set dedup      2          String map     HELLO
Interval       5050       inject/select  30
SortedColl     1..3
```

No `BOOT FAIL`. Every functional exercise returns the correct answer:
collections, Dictionary, Set dedup, `(1 to: 100) inject:into:`,
SortedCollection ordering, Fraction arithmetic (`(1/2)+(1/3) = 5/6`),
WriteStream, `collect:`, `select:`.

**And it loads into the live IDE.** With `WINDART_ST_WORLD` set:

```
ST-WORLD: imported 172 classes, 5 boot chunks from 97 files
ST-GAME galaxigans: imported 7 classes from 1 files
ST-WORLD: 179 Smalltalk classes browsable
ST-BROWSE: smalltalk -> 179 classes
ST-BROWSE: class Fraction
```

The bilingual browser shows `smalltalk` as a library beside `dart:core` /
`dart:io` / `dart:win` (Libraries went 16 → 17), lists all 179 classes, and
renders real `.mst` source with Smalltalk syntax highlighting —
`browser_smalltalk_class.png`. `ws_language.dart` compiled **1411 functions,
148 optimized** with the world loaded (vs 875/35 without), so the corpus really
did go through the arm64 optimizing backend.

**Why this is unsurprising in hindsight:** `.mst` files are *source*. The ST
front-end (`dart_st`) compiles them to Dart flow-graph IR — no machine code, no
OS calls — which is exactly why the porting plan predicted `dart_st` would come
across for free (§3, "arch-agnostic by construction"). It did.

## What does NOT port — measured properly this time

> **CORRECTION.** An earlier revision of this note claimed "19 classes across 26
> files are Cocoa-bound and will fail at runtime". That was produced by grepping
> for the *word* `Cocoa`, which is far too broad: it matches the library **name**
> `dart:cocoa` — which is what the Smalltalk front-end is called on **Windows
> too** (registered by `st-tree.patch`, nothing to do with AppKit) — and matches
> comments about AppKit coordinate flipping. The real gap is much smaller and is
> measured below.

The correct question is not "which files say Cocoa" but **"which primitives does
the world ask for that the Windows `dart:cocoa` does not define?"** Extracting
every `<stprim: …>` in the 97 files and checking each against
`port-win/dart_st/cocoa.dart`:

```
world requests 97 distinct stprim names
defined in cocoa.dart : 81
MISSING               : 16
```

The 16, and they are almost all one subsystem:

```
stGpAddFrame   stGpClearBlocks  stGpEffect      stGpHide
stGpLinePal    stGpOnReset      stGpOnStep      stGpPlaceFrame
stGpPlaySlot   stGpResetBlock   stGpShader      stGpShaderParam
stGpStepBlock  stGpText         stGpTextClear            (15 × GamePane)
stHostStoreClass                                         (1 × host service)
```

And they live in exactly **two** files:

| file | uses of a missing primitive |
|---|---|
| `80_gamepane_wiring.mst` | **15** |
| `63_cocoaui_stub.mst` | 1 |
| every `Cocoa*` UI class (`49_cocoa`, `64_cocoaui`, `66_cocoabrowser`, `67_cocoafind`, `68_cocoaeditor`, `70_cocoacanvas`, `73_cocoadebugger`, …) | **0** |

**No Cocoa/AppKit primitive is missing at all.** The `Cocoa*` classes work
because their primitives route through *pluggable Dart hooks*, not
Objective-C — see the view-server trace below.

### Why the Cocoa* classes are fine — the view-server

The Smalltalk GUI never touches AppKit. `81_appui.mst`'s `AppUI` declares each
widget method as `<stprim: stAppUi*>`; those primitives are **pure Dart** in
`cocoa.dart`, dispatching through a closure the language isolate installs:

```
ST    build: ui [ ui button: 'go' title: 'Go' frame: {…} onClick: [ … ] ]
  ->  81_appui.mst   AppUI >> button:title:frame:onClick:   <stprim: stAppUiButton>
  ->  cocoa.dart     stAppUiButton(…) => _stAppUi('button', […])
  ->  stAppUiHook    (language.dart:2855 binds it to the live AppSurface)
  ->  AppSurface     _out.send(['appui', name, gen, batch])        language.dart:2606
  ->  workspace.dart _appApply(msg[3])                             workspace.dart:441
  ->  dart:win       Win_surfaceApply
  ->  C++            ViewServer::Apply  (win_view.cpp)  -> real Win32 controls
```

Host-neutral end to end, which is why `tcl/test_c4_app.tcl` **passes on arm64**
("app rendered + button event fired").

### The real fix

Add 16 shim functions to `port-win/dart_st/cocoa.dart` routing the `stGp*`
verbs onto the **existing** `dart:win` gamepane natives (`gpApply` and friends
are already implemented and proven — coindash and tiletest render). That is a
Dart-side shim layer, not a rewrite of the world, and it should also resolve the
`intermediate_language.h:3345` abort below at its root.

Note `83_gamepane_direct.mst` uses **no** missing primitive — excluding it in the
experiment below was unnecessary; only `80_gamepane_wiring.mst` matters.

<details>
<summary>Superseded: the original over-broad grep (kept for the record)</summary>

The following 19 class names and 26 files merely *mention* the string `Cocoa`
and were wrongly reported as a porting burden:</details>

```
Cocoa            CocoaBrowser2Face  CocoaFind      CocoaPool
CocoaBrowser     CocoaCanvas        CocoaFindFace  CocoaTableFace
CocoaBrowser2    CocoaDebugger      CocoaHelp      CocoaToolbarAction
CocoaEditor      CocoaDebuggerFace  CocoaOutliner  CocoaUI
CocoaFile        CocoaPad           CocoaUIStub
```

Files carrying Mac-facing code: `49_cocoa`, `49a_cocoafile`, `50_cocoapad`,
`63_cocoaui_stub`, `64_cocoaui`, `65_cocoadelegate`, `66_cocoabrowser`,
`67_cocoafind`, `68_cocoaeditor`, `69_cocoaoutliner`, `70_cocoacanvas`,
`71_cocoahelp`, `72_cocoabrowser2`, `73_cocoadebugger`, `74_supervisor`,
`34_tools`, `47_worker`, `61_posix_io`, `61a_accelerate` (the Accelerate
framework), `61e_fftchart`, `80_gamepane_wiring`, `81_appui`,
`83_gamepane_direct`, `82_number_math`, `58a_base64`, `01_object`.

(End of the superseded material. The measured gap is the 16 primitives above,
in 2 files — not this list.)

## Consequences for AS6

- The class library needs **no porting** — it is already exercised and correct.
- The GUI classes need **no porting either** — the Smalltalk widget path already
  runs on the Win32 view-server (`test_c4_app.tcl` passes).
- The whole gap is **16 primitives in 2 files**, 15 of them GamePane, fixed by
  adding Dart shims in `cocoa.dart` over the already-working `dart:win` gamepane
  natives.
- The App pane can be driven headlessly once an ST app class exists that builds
  through the Windows widget protocol — then the selftest can issue
  `ui apprun <StClass>` and the `calc`-is-null guard becomes a live path.
- `WINDART_ST_WORLD` selects the corpus (env var, else `<repo>/st/world`), in
  both `workspace.dart` and `tcl/test_c2_browser.tcl`.

## Two files actively CRASH the VM — `80_gamepane_wiring` / `83_gamepane_direct`

Stronger than "won't run". Driving the live IDE over the TCL control plane
(`ui stgame MandelZoom`) aborts the VM:

```
runtime/vm/intermediate_language.h: 3345: error: expected: !function.IsNull()
```

That is `StaticCallInstr`'s constructor rejecting a null target — the ST
flow-graph builder emitting a static call to a function it could not resolve.

**Not arm64-specific.** The x64 build from the same tree produces the *identical*
assert at the *identical* line. (First comparison was invalid and nearly led to
a wrong call: the arm64 instance had the world loaded and the fresh x64 one did
not, so `ui stgames` reported `true` for every game on arm64 and `false` on x64
— the games' sources simply were not there. Re-run with the world actually
imported into x64, it dies too.)

**Isolated to two files.** Re-importing the world with
`80_gamepane_wiring.mst` (36 `GamePane` references) and `83_gamepane_direct.mst`
(5) removed — 95 of 97 files:

| | double `stimport` | `ui stgame MandelZoom` | VM |
|---|---|---|---|
| full 97-file world | ok | **abort** | dead |
| 95 files (no gamepane wiring) | ok | ok | **alive** |

Those two files define Mac-side `GamePane` methods that collide with the
**Windows-ST** `GamePane` primitives supplied by `galaxigans.mst` — visible in
the import log as `[lastwins] GamePane >> point:y:color:`,
`>> primDefineSprite:rows:`, `Sound >> primPlay:`, `Tune >> primPlayTune:`.
Whichever side loses the `lastwins` race leaves a selector whose implementation
is absent, and the ST compiler then builds a call to nothing.

**Consequence:** with the two files excluded the IDE is stable and the world is
fully browsable, but ST games cannot render (`gpsnap: gamepane: not open`) —
that wiring is exactly what bridges ST `GamePane` to the D3D11 pane. So those
two files are the concrete, minimal port target for Smalltalk games on Windows,
and they are the first place to spend the `Mac-ST → Windows-ST` effort.

**Safe configuration today:**
```
set WINDART_ST_WORLD=<a world dir without 80_gamepane_wiring.mst and 83_gamepane_direct.mst>
```

## Caveats

Only `st/world` (97 files) was tested. `st/world/bench` (12),
`st/test/features` (13) and `st/examples` (3) are untested. "Loads and browses"
is proven for all 179 classes; "executes correctly" is proven for the nine core
exercises above, not for every method.
