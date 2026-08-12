# `st/world` — the Smalltalk world corpus (vendored)

## Where it came from

| | |
|---|---|
| Repo | `https://github.com/albanread/MACDARTV1.git` |
| Branch | **`dartui-workspace`** (not `main` — `main` carries no `.mst` at all) |
| Commit | `68b168961f4413ea228278ee000c8ed8ec306820` (2026-08-05) |
| Path | `macdart/st/world` |
| Vendored | 2026-08-12 — 97 top-level `.mst` + 12 in `bench/`, byte-identical (SHA-256 verified per file) |

Same author, same project family, so this is a copy of our own code rather than
a third-party dependency — unlike the Dart 1.24.3 sources, which stay
un-vendored and are fetched by `port-win/extract.py`.

## Why it is vendored now

It used to live only in the MACDART checkout, which `.gitignore` excludes
(*"its own repo; obtain from github separately"*). That made a fresh clone of
this repo unable to load a world at all: `stimport` failed, and only the 7
classes from `demos/galaxigans.mst` were browsable. Worse, the corpus was on a
**non-default branch** of the sibling repo, so it was not obvious it existed —
`MACDARTV1/main` has zero `.mst` files.

`test/workspace.dart` already defaults `_stWorldDir` to `<repo>/st/world`, so
dropping the corpus here makes the default path work with no configuration.

## It is Mac-authored, and it runs unmodified

Worth stating plainly, because the expectation was the opposite: **all 97 files
boot on Windows ARM64 and 179 classes browse.** The class library needed no
porting. `.mst` is *source* — the ST front-end compiles it to Dart flow-graph
IR, not machine code — so it is host-neutral by construction.

Verified functionally, not just "it loads" (`dart.exe st_world_run.dart st/world`):
OrderedCollection `inject:into:` → 6, Dictionary → 30, Set dedup → 2,
`(1 to: 100) inject:into:` → 5050, SortedCollection → 1..3,
`(1/2)+(1/3)` → `5/6`, WriteStream, `collect:`, `select:`.

The Mac-facing parts are **not** the `Cocoa*` classes (their primitives route
through pluggable Dart hooks, so they are fine). The real gap was 16 missing
`stprim`s — 15 GamePane + `stHostStoreClass` — used by exactly two files,
`80_gamepane_wiring.mst` and `63_cocoaui_stub.mst`. Those shims are now in
`port-win/dart_st/cocoa.dart`, so nothing here needs editing. See
`port-arm64/ST_WORLD_FINDINGS.md` for the full measurement.

One dialect note: shader bodies here are **Metal** (`GamePane >> shader:` even
names the parameter `mslSource`). `GpShaderPane::compile` translates MSL→HLSL at
compile time, so they work on D3D11 unchanged.

## Selecting a different corpus

`WINDART_ST_WORLD` overrides the path in both `test/workspace.dart` and
`tcl/test_c2_browser.tcl`; unset, both use this directory.

## Not vendored

Still in MACDARTV1 only, and not required to run the world:
`st/test/features` (13 files), `st/examples` (3), `st/audit`, `st/bench`.
`bench/` here is the subdirectory *inside* `world/`; note the loader lists a
single directory non-recursively, so `bench/` is carried for reference and is
not imported by `stimport`.
