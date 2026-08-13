# A Smalltalk world, byte-identical, on a Snapdragon

*97 Mac-authored source files boot unmodified on Windows-on-ARM. Metal
shaders run on D3D11. The IDE answers to TCL. This is what the port was
for.*

The TALK in WINDARTTALK is Smalltalk: a live class library and IDE hosted
*inside* the Dart VM. Smalltalk source (`.mst` files) is compiled by a
front-end straight into the VM's flow-graph IR — the same intermediate
form Dart itself lowers to — and from there one JIT, one optimizer, and
one garbage collector serve both languages. One VM, bilingual. (Headless,
the Smalltalk side holds its own: the pinned benchmarks beat Cog on six of
seven, with deltablue at near-parity.)

When the ARM64 port reached the point of loading the Smalltalk world, the
working assumption — mine included — was that it wouldn't travel: the
world was authored on a Mac, against a Mac build, with classes named
`Cocoa`-this and game code written in Metal. The assumption did not
survive contact, and the ways it failed are the story.

## Source is the ultimate portable format

All 97 world files boot on Windows-on-ARM64 **byte-identical** — vendored
with per-file hash verification, no edits. 179 classes browse in the IDE
with their real source. Collections, Fractions, sorted collections,
streams, the benchmark dashboard: all of it runs.

No magic; an architecture lesson. `.mst` is *source*. The front-end lowers
it to flow-graph IR, and machine dependence enters only below that line —
in the JIT backend the port already supplied. A class library written
against a VM's semantics, rather than against a platform, is host-neutral
by construction.

The genuinely platform-facing surface turned out smaller than anyone
guessed, and we only learned its true size by counting rather than
grepping. A first survey said "19 Cocoa-bound classes across 26 files need
porting" — an over-broad text match on the word "Cocoa," which also
matches the *library name* used on Windows and a pile of comments. The
real number, counted by which VM primitives the world requests versus
which the Windows side defines: **16 missing primitives, used by exactly
two files**. The `Cocoa*` UI classes needed *zero* — they were written
against pluggable hooks all along. Rule of thumb: measure your porting
surface; folklore overestimates it.

## The GUI nobody had to port

How does a Mac-authored Smalltalk UI class make windows on Win32? It
doesn't — and never did on the Mac either. The world's `AppUI` builds a
*description* of the interface and hands it through a primitive to a
**view server**: Smalltalk → a Dart hook → a batched message across the
embedder boundary → a C++ `ViewServer::Apply` that realizes native Win32
controls. On the Mac, the same description became AppKit. The Smalltalk
never knew, and still doesn't.

Old idea, still undefeated: the moment a UI is data rather than calls, the
platform is a rendering detail.

## Metal shaders on D3D11

The games were the entertaining part. `Galaxigans` — our Galaxians-alike —
draws its cosmos with a fragment shader written in **Metal Shading
Language**, because that is what the Mac's game pane spoke. The Windows
pane speaks HLSL through D3DCompile.

Rather than fork every game, the shader compiler grew a dialect shim:
`fract`→`frac`, `mix`→`lerp`, `inversesqrt`→`rsqrt`, two-argument
`atan`→`atan2`, plus a structural rewrite of the MSL entry point (the
`fragment float4 fmain(VOut in [[stage_in]], …)` signature becomes an HLSL
`SV_Target` function; attribute clutter stripped; the uniform-block prefix
dissolved). One translation deserves its own warning label: GLSL-family
`mod` is floor-based, HLSL's `fmod` truncates — **they differ in sign for
negative operands** — so `mod` maps to a small floor-mod helper, not to
the lookalike. Sign bugs in shaders don't crash; they just look subtly and
maddeningly wrong.

With the shim in place the Mac-authored shader runs unmodified, and
Galaxigans renders complete on the Adreno: starfield on layer 0, sprite
fleet, HUD, particles, sound.

## An IDE you can script from TCL

Debugging a live windowed IDE by clicking on it does not scale, so the
project drives everything through a control plane: the Dart VM's service
protocol — a WebSocket speaking JSON-RPC — with a TCL library over it.
Every battery test is a `tclsh` script: boot the IDE, import the world,
browse a class, run a game, screenshot the pane, assert on the bytes.
Claude runs the whole battery without touching the mouse, which is rather
the point.

Two pleasant Windows-on-ARM footnotes. First, no toolchain hunt: Git for
Windows quietly ships a **native arm64 tclsh**. Second, the scriptability
earned its keep immediately — the battery caught a VM abort in one
game-loading path and, run against both builds, proved it predated the
port rather than being caused by it. That is the sort of triage manual
clicking gets wrong.

## Where it lands

Add the earlier articles' work — comparisons at parity, frames blitted
through unified memory — and the stack stands complete: a Smalltalk class
library authored on a Mac, compiled by a Dart VM's JIT to native ARM64,
computing fractal frames within 3% of hand-written Dart, writing pixels
into memory the GPU reads directly, inside an IDE a shell script can
drive.

Nearly every layer of that sentence was, at some point, the thing we
assumed would not work.

*This closes the current arc. The open items — one arm64-only assert under
aggressive recompilation, and the 12% code-generation gap the emulator
exposed — are the next one.*
