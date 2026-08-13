# A Smalltalk world, byte-identical, on a Snapdragon

*97 Mac-authored source files boot unmodified on Windows-on-ARM. Metal
shaders run on D3D11. The whole IDE answers to TCL. This is the payload
the port was for.*

The TALK in WINDARTTALK is Smalltalk: a live class library and IDE hosted
*inside* the Dart VM. Smalltalk source (`.mst` files) is compiled by a
front-end straight into the VM's flow-graph IR — the same intermediate
form Dart itself compiles to — and from there the same JIT, the same
optimizer, the same garbage collector serve both languages. One VM,
bilingual.

When the ARM64 port reached the point of loading the Smalltalk world, the
working assumption — ours included — was that it wouldn't travel: the
world was authored on a Mac, against a Mac build, with classes named
`Cocoa`-this and game code full of Metal. The assumption was wrong in the
best way, and the ways it was wrong are the story.

## Source is the ultimate portable format

All 97 world files boot on Windows-on-ARM64 **byte-identical** — vendored
with per-file hash verification, no edits. 179 classes browse in the IDE
with their real source. Collections, Fractions, sorted collections,
streams, the benchmark dashboard: all of it just runs.

There is no magic; there is an architecture lesson. `.mst` is *source*.
The front-end lowers it to flow-graph IR, and machine dependence enters
only below that line — in the JIT backend the port already supplied. A
class library written against a VM's semantics, rather than against a
platform, is host-neutral by construction.

The genuinely platform-facing surface turned out to be startlingly small,
and we only learned its true size by measuring rather than grepping. A
first survey said "19 Cocoa-bound classes across 26 files need porting" —
an over-broad text match on the word "Cocoa." The real number, counted by
which VM primitives the world actually requests versus which the Windows
side defines: **16 missing primitives, used by exactly two files**. The
`Cocoa*` UI classes needed *zero* — they were already written against
pluggable hooks. The lesson generalizes: measure your porting surface;
folklore overestimates it.

## The GUI nobody had to port

How does a Mac-authored Smalltalk UI class make windows on Win32? It
doesn't — and never did on the Mac either. The world's `AppUI` builds a
*description* of the interface and hands it through a primitive to a
**view server**: Smalltalk → a Dart hook → a batched message over the
embedder boundary → a C++ `ViewServer::Apply` that realizes real Win32
controls. On the Mac the same description became AppKit. The Smalltalk
never knew.

Old idea, still undefeated: the moment your UI is data rather than calls,
the platform is a rendering detail.

## Metal shaders on D3D11

The world's games were the fun part. `Galaxigans` — our Galaxians-alike —
draws its cosmos with a *fragment shader written in Metal Shading
Language*, because that is what the Mac's game pane spoke. The Windows
pane speaks HLSL through D3DCompile.

Rather than fork every game, the shader compiler grew a dialect shim:
`fract`→`frac`, `mix`→`lerp`, `inversesqrt`→`rsqrt`, two-argument
`atan`→`atan2`, plus a structural rewrite of the MSL entry point
(`fragment float4 fmain(VOut in [[stage_in]], ...)` becomes an HLSL
`SV_Target` function; attribute clutter stripped; the uniform-block prefix
dissolved). One translation is a landmine worth naming: GLSL-family `mod`
is floor-based, HLSL's `fmod` truncates — they *differ in sign for
negative operands* — so `mod` maps to a small floor-mod helper, not to the
lookalike. Sign bugs in shaders don't crash; they just look subtly,
maddeningly wrong.

With the shim in place the Mac-authored shader runs unmodified, and
Galaxigans renders complete on the Adreno: starfield shader on layer 0,
sprite fleet, HUD, particles, sound.

## An IDE you can script from TCL

Debugging a live windowed IDE by clicking on it does not scale, so the
project drives everything through a control plane: the Dart VM's service
protocol (a WebSocket speaking JSON-RPC) with a TCL library over it. Every
battery test is a `tclsh` script: boot the IDE, import the world, browse a
class, run a game, screenshot the pane, assert on the bytes.

Two pleasant Windows-on-ARM footnotes. First, no toolchain hunt: Git for
Windows quietly ships a **native arm64 tclsh**. Second, the scriptability
paid for itself immediately: the battery caught a VM abort in a specific
game-loading path — and, run against both builds, proved it was a
pre-existing bug rather than an arm64 one, the kind of triage that manual
clicking gets wrong.

## Where it lands

Add the previous articles' work — comparisons at parity, frames blitted
through unified memory — and the stack stands complete: a Smalltalk class
library authored on a Mac, compiled by a Dart VM's JIT to native ARM64,
computing fractal frames within 3% of hand-written Dart, writing pixels
into memory the GPU scans out directly, inside an IDE a shell script can
drive.

Every layer of that sentence was, at some point in this project, the thing
we assumed would not work.

*This closes the current arc of the Snapdragon series. The open items —
one arm64-only assert under aggressive recompilation, and the 12% code-gen
gap the emulator exposed — are the next one.*
