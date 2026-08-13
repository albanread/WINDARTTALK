# Unified memory is real — we measured it

*What the Adreno X1-45's shared memory actually buys a CPU-rendered
framebuffer. Mostly good news, one trap.*

Every SoC datasheet says "unified memory." The claim is cheap to make —
CPU and GPU share DRAM — and historically cheap to under-deliver on,
because sharing silicon is not the same as sharing *inexpensively*. The
port gave us a reason to pin it down: WINDARTTALK's game pane is an
indexed-colour framebuffer that Dart (and Smalltalk) code fills on the CPU
every frame, so the upload path decides whether demos like a live-zooming
Mandelbrot are smooth or embarrassing.

Before touching the renderer, Claude wrote standalone probes. The machine:
Snapdragon X, Adreno X1-45, D3D11 feature level 11_1. The probes confirmed
the headline — `UMA: YES`, 16 GB shared against a token 128 MB carve-out,
tile-based deferred renderer — and then measured the parts the datasheet
does not mention.

## Result 1 — the textbook upload path wastes most of the machine

The engine uploaded frames with `UpdateSubresource` into `DEFAULT`-usage
textures: the standard path, and on a discrete GPU a sensible one, since
everything crosses the bus regardless. On UMA it is a pure tax — the
driver stages your bytes, the GPU copies them again, and both copies
traverse the *same physical DRAM* the buffer already lives in.

Switching the texture to **`D3D11_USAGE_DYNAMIC`** and the upload to
**`Map(WRITE_DISCARD)`** with a row-pitch-aware copy — no Dart-side change
at all — measured **~8× faster**. Plotting *directly into the mapped
pointer*, skipping the CPU-side scratch buffer entirely, measured
**5.7–19.4×** depending on access pattern. On unified memory, "upload" is
a polite fiction; the honest operation is *write it where the GPU will
read it*.

We checked the switch changed nothing visually the boring way: SHA-256 of
the rendered output, byte-for-byte identical on the static test scene.

## Result 2 — readback costs the same as memcpy

The result that raised eyebrows here: **reads from mapped GPU memory run
at ordinary heap speed** — 0.059 ms/MiB, cache-warm. On a discrete card,
reading back a framebuffer is a PCIe excursion that engines spend whole
architectures avoiding. Here it is just memory; the mapping is fully
cached.

That quietly reopens a toolbox console programmers will remember:
read-modify-write of a live framebuffer, feedback effects, deciding what
to draw next frame by looking at the last one. The mental model shifts
from "the GPU is a remote server you post buffers to" toward "the GPU is a
coprocessor pointed at your arrays."

## Result 3 (negative) — `MapOnDefaultTextures` is not the shortcut it sounds

D3D11.3 offers `MapOnDefaultTextures`: mapping DEFAULT-usage textures
directly, which sounds like the UMA dream ticket. Measured, so you need
not: on this driver it accepts only `BindFlags = 0` textures — so you copy
into a bindable texture anyway — and `Unmap` performs cache maintenance
proportional to resource size, 0.064 ms at 64 KB rising to 0.867 ms at
8 MB, on every unmap. It loses to `WRITE_DISCARD` at every size we tried,
and double-buffering does not rescue it. It cost an afternoon, and the
datasheet was never going to mention it.

## Wiring it to the top of the stack

The measurements were in service of product, not benchmarks, and the fast
path now runs the whole way up:

- The engine maps the pane's active slot and hands the pointer *into the
  VM* as an external typed array — `Dart_NewExternalTypedData` over the
  mapped bytes. No copy; no finalizer (D3D owns the memory).
- The Smalltalk `MandelZoom` demo computes a 320×240 frame of palette
  indices into a reused `ByteArray` and hands it over with one
  **`directBlit:`** — one bulk copy into GPU-shared memory rather than
  76,800 per-pixel drawing commands.
- Two contracts to respect: `WRITE_DISCARD` renames the buffer each frame,
  so the pointer is good for exactly one frame — fetch, fill, present,
  repeat — and the engine unmaps at frame start, so the frame presented is
  never the one still being written.

## What we'd tell a friend with a Snapdragon

1. On UMA, `UpdateSubresource` into DEFAULT textures is the *slow* path.
   `DYNAMIC` + `Map(WRITE_DISCARD)` is one flag and one call away; it paid
   8× here.
2. Readback is no longer a sin. Budget it like memcpy, because that is
   what it is.
3. Measure `MapOnDefaultTextures` before believing in it. On this driver
   it is strictly worse.
4. The old console habits are back on the table. Plan the frame around
   shared memory, not around a bus that is not there.

*Next: the Mandelbrot that stayed slow after all of this — because the
bottleneck was never the GPU.*
