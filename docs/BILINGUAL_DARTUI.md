# Bilingual dartui — rolling Smalltalk support on the Windows Dart VM

> **Status:** design. **Prereq (done):** the `dart:cocoa` Smalltalk front-end runs
> headless on windart — the 97-file world boots, conformance 38/0, and pinned
> benchmarks beat Cog (Pharo) on 6/7 with deltablue at near-parity. This document
> designs how to surface that ST layer *in the `dartui` GUI* so you can browse,
> edit, and run Smalltalk — apps, demos, and games — alongside Dart, live.

## 1. The bet, in one paragraph

`dartui` is already a working Dart IDE: a **Do It** workspace, a class **browser**,
a live **editor**, a VM-service **debugger**, a **Direct2D canvas**, and a
**Direct3D game pane** — all materialized through the `dart:win` view-server. The
Mac team already built the bilingual version of exactly this, and — crucially —
they built it so the **language brain is separate from the GUI**. So we do **not**
re-solve "how do you make an IDE bilingual"; we **port their proven brain
verbatim and rebuild only the thin Windows UI shell** on the `dart:win` controls
dartui already has. Smalltalk-in-the-GUI is mostly a *wiring* job, like the
headless port was.

## 2. Architecture — two isolates, one image

MACDART's IDE is a **two-isolate** design, and the isolate boundary *is* the
portability boundary:

```
┌─ UI isolate (REBUILD on dart:win) ─┐   dart:isolate wire   ┌─ LANGUAGE isolate (PORT ~verbatim) ─┐
│ dartui shell: tabs, editor,        │  ask(verb, arg) ───►  │ language.dart — the bilingual brain: │
│ browser view, app pane, game pane, │                       │  • classify Dart vs ST (by shape)    │
│ debugger client.                   │  ◄─── ['appui']       │  • Do It / Accept / reload           │
│ Paints command envelopes,          │       ['draw']        │  • SQLite image + versioning         │
│ forwards GUI events.               │       result/error    │  • browser data (_hostCall)          │
└────────────────────────────────────┘                       │  • hosts the running ST/Dart app     │
                                                              └───────────────┬──────────────────────┘
                                                                 dart:cocoa→dart:win │ ST natives (DONE)
                                                              ┌───────────────▼──────────────────────┐
                                                              │ dart:cocoa bridge + st_natives.cc     │
                                                              │ stLoad/stRun/stSend/stNew + ST_* refl │
                                                              │ (OS-agnostic — already runs on windart)│
                                                              └────────────────────────────────────────┘
```

**Why two isolates.** The language isolate holds the live image and the running
app; the UI isolate only paints and forwards events. This is what lets a running
ST game keep ticking while you edit, and what lets the debugger attach over the
VM service. windart already treats isolates as load-bearing (every demo/game runs
in one), so this is a natural fit, not a new concept.

**The wire protocol** (`dart:isolate` `SendPort`, fully portable) is the seam we
re-use unchanged. Verbs already defined by `language.dart`:
`doit · accept · acceptMany · acceptLive · reset · remove · versions · rollback ·
classes · members · classsrc · find · senders · alldecls · vmstats · apps ·
apprun · appstop · appbuild · appevent · stimport · stbrowser · stdemo · stdemos ·
stnamecls · stgame · stgamestop · stgames · sthaltarm · ping`.

### What ports vs what we rebuild

| Piece | Source | Port strategy |
|---|---|---|
| **Bilingual brain** | `language.dart` (2330 lines) | **Port verbatim.** Swap `import 'dart:cocoa'` → `dart:win` for `wsEval`/`wsReload`/`Db`; everything else is OS-neutral. |
| **ST runtime + reflection** | `dart:cocoa` + `st_natives.cc` | **Done** — already runs on windart. |
| **Wire protocol** | `dart:isolate` verbs | **Port verbatim** — transport is platform-neutral. |
| **Compile/reload + image** | `_acceptMany`→`_rebuildAndReload`→`_stReloadAll`, SQLite `decls`/`versions` | **Port verbatim** — windart already has the SQLite image (`windart_sqlite_natives`). |
| **Debugger logic** | VM-service client | **Port verbatim** — cross-platform; steps *both* languages (ST compiles to Dart IL). |
| **UI shell** (tabs, editor text view) | `workspace.dart` (Cocoa) | **Rebuild** on dartui's `Ui` widgets (windart already has editor/tabs/menus). |
| **Class browser** | `CocoaBrowser2` (an ST WKWebView) | **Rebuild** as a native `dart:win` widget calling the portable `_hostCall`/`classes`/`members`/`classsrc` verbs. |
| **App pane renderer** | `appApply` (NSView) | **Rebuild** — realize the `['appui']` command list with `dart:win` controls. |
| **Game pane** | `gp_engine.mm` (Metal) | **Rebind** — the `gp*` **draw-command stream is identical**, and windart's D3D11 `gp*` natives already exist. |

**Rule of thumb:** if it decides *what* to show or run, it ports; if it *draws
pixels or native controls*, it's rebuilt on `dart:win`. The former is ~90% of the
line count.

## 3. Two design decisions to lock first

1. **Adopt the two-isolate seam.** windart's current `workspace.dart` is a
   single-isolate IDE that calls `dart:win` directly. To reuse `language.dart`
   verbatim we introduce the **language isolate** and make the existing workspace
   the **UI-isolate shell** that talks to it over the wire. *Recommended* — it's
   the proven design and maximizes reuse. (Alternative: fold `_doit`/`_accept`
   into the current single isolate; faster to first light, but re-solves the
   compile/reload/image plumbing by hand and diverges from upstream.)
2. **Language is inferred, not toggled.** There is no Dart/ST switch. `_doit`
   auto-detects: not-Dart-looking **and** a clean `stCheck` parse → run as ST,
   else Dart (`25 sqrt` → `5.0` with no prefix; a `st>` prefix forces ST). Keep
   this — it's what makes it feel like *one* environment, not two.

## 4. Rolling rollout — every phase ships something usable

Ordered so each phase is independently demoable and de-risks the next.

### C0 — the seam (foundation)
Stand up the language isolate; port `language.dart` with a `dart:win` binding for
`wsEval`/`wsReload`/`Db`. No new UI.
**Ships:** `ask('doit','25 sqrt')` returns `5.0` and `ask('doit','(2+3)*7')`
returns `35` over the wire — bilingual eval proven end to end, headless of UI.

### C1 — ST Do It in the workspace
Route the existing **Do It** button through the wire → `_doit` (auto-detect).
Print results/errors to the transcript pane.
**Ships:** type Smalltalk *or* Dart in the workspace, click Do It, get the
answer. The single most convincing "it's bilingual now" moment, for ~a day of
wiring (the brain is `_doit`, already ported).

### C2 — ST class browser (read)
Rebuild the browser tab as a `dart:win` tree/list + source pane, backed by the
portable `_hostCall` verbs (`packageTree`/`classSource`/`methodSource`) and
`classes`/`members`/`classsrc`. Show ST classes with **real method source** (the
image keeps it) next to Dart classes (mirrors, signatures only).
**Ships:** navigate the 97-file world — packages → classes → methods → source —
and Dart libraries, in one browser.

### C3 — ST editor + live compile (write) — *the living system*
Wire **Accept** through `_acceptMany`→`_rebuildAndReload`→`_stReloadAll`, with the
image write-after-success + append-only `versions` rollback. A bad ST parse
reports line/col before any write; the dispatch caches flush on reload (the arc's
`ClearSendCache`, already ported).
**Ships:** edit an ST method, Accept, and see the change live in a running
object — with rollback if it doesn't compile. This is the Smalltalk promise.

### C4 — ST apps (declarative widgets)
Rebuild `appApply` to realize the `['appui']` command list (`label/field/button/
checkbox/slider/canvas/…`) with `dart:win` controls; wire `stAppUiHook` so an ST
`AppUI` app (`world/81_appui.mst` style) drives it. GUI→ST callbacks come free:
an ST block is stored as an ordinary Dart closure and fired by `appevent`.
**Ships:** an ST app renders as native dartui widgets, and clicking a button runs
its ST handler.

### C5 — ST demos & games (the fun one)
Port the pull-tick loop (`_stGame`→`stInvokeStatic(cls,'launch')`→per-frame
`stepWithKeys:`→`stGpTake()`→`['draw']`). The `gp*` draw vocabulary
(`gppal/gpcls/gpline/gpblit/gpscroll/…`) is **identical** and windart's D3D11
`gp*` natives already exist — so this is a **rebind + keycode map**, not a new
engine. Rebind the world's game classes from the Cocoa natives to `Win_gp*`.
**Ships:** an ST demo/game from the world (mandelbrot, breakout) runs in dartui's
Direct3D game pane, keyboard and all.

### C6 — bilingual polish + the rolling catalog
- **Rolling app/demo/game catalog** — the `apps`/`stdemos`/`stgames` verbs already
  enumerate droppable `.mst` apps; wire a dartui gallery so **dropping an `.mst`
  makes a new app/demo/game appear** (this *is* "rolling support").
- **Debugger** — point the existing VM-service client at `st:mst/N` scripts, arm
  `self halt` (`sthaltarm`). Needs the deferred `object.cc` source-map hunk.
- **Inspector** — new, small: a `dart:win` object view backed by
  `stSend(obj,'printString')` + `stInstVarNamesOf` + `instVarAt:`.
- **Find / senders** — `find`/`senders` verbs (portable) → a results pane.

## 5. Leverage & risks

**Leverage (why this is tractable):**
- `language.dart` — the entire bilingual/compile/reload/image brain — ports with a
  one-line import swap.
- The `gp*` game command stream is byte-identical; windart's game pane already
  runs it. ST games are ~a rebind.
- ST closures *are* Dart closures → GUI→ST event handling is free.
- The debugger already steps ST (it's Dart IL underneath).
- The SQLite image, editor, canvas, game pane, and widget view-server already
  exist in dartui.

**Risks / open items:**
- **The two-isolate refactor of windart's current workspace** is the biggest
  single piece of new work — a shell rewrite, not new algorithms.
- **`CocoaBrowser2` does not port** (WKWebView/objc); the browser UI is genuinely
  rebuilt (but on the portable `_hostCall` backend).
- **`object.cc` debugger source-map** hunk was deferred in the headless port;
  C6's debugger needs it.
- **FFI-backed world apps** (sockets/accelerate) stay stubbed until the Win64 FFI
  trampoline lands — irrelevant to C1–C5.

## 6. Sequence summary

`C0 seam → C1 Do It → C2 browse → C3 edit-live → C4 apps → C5 games → C6 catalog+debug`.
Each ships. The brain (`language.dart` + the ST runtime) is done or ports
verbatim; the work is the `dart:win` UI shell and the game rebind.
