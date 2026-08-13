# Unified memory is real — we measured it

*What the Adreno X1-45's shared memory actually buys a CPU-rendered
framebuffer: 8× for one flag, free readback, and a negative result.*

Every SoC datasheet says "unified memory." The claim is easy to make —
CPU and GPU share the same DRAM — and easy to under-deliver on, because
sharing silicon is not the same as sharing *cheaply*. Our port gave us a
reason to find out precisely: WINDARTTALK's game pane is an indexed-color
framebuffer that Dart (and Smalltalk) code fills on the CPU every frame,
and the upload path is the whole ballgame for demos like a live-zooming
Mandelbrot.

So before touching the renderer we wrote probes. The machine: Snapdragon X,
Adreno X1-45, D3D11 feature level 11_1. The probes confirmed the headline
(`UMA: YES`, 16 GB shared against a token 128 MB carve-out, tile-based
deferred renderer) and then measured the parts the datasheet does not say.

## Result 1: the default upload path wastes most of the machine

The engine uploaded frames with `UpdateSubresource` into `DEFAULT`-usage
textures — the textbook path, and on discrete GPUs a perfectly reasonable
one, because everything crosses the bus anyway. On UMA it is a pure tax:
the driver copies your bytes into a staging area, then the GPU copies them
again, and both copies traverse the *same physical DRAM* your buffer
already lives in.

Switching the texture to `D3D11_USAGE_DYNAMIC` and the upload to
`Map(WRITE_DISCARD)` + row-pitch-aware copy — no Dart-side change at all —
measured **~8× faster**. Going further and *plotting directly into the
mapped pointer* (no CPU-side scratch buffer at all) measured **5.7–19.4×**
depending on access pattern. On a unified-memory machine, "upload" is a
fiction; the honest operation is "write it where the GPU will read it."

We verified the switch changed nothing visually the honest way: SHA-256 of
the rendered output, byte-for-byte identical on the static test scene.

## Result 2: readback is free, and that changes what's reasonable

The result that genuinely surprised us: **reads from mapped GPU memory cost
the same as reads from the ordinary heap** — 0.059 ms/MiB, cache-warm. On
a discrete GPU, reading back a framebuffer is a PCIe crossing with
microsecond latencies and driver ceremony; engines are architected for
years around *never doing it*. Here it is just memory. The mapping is
fully cached.

That makes patterns practical that console-era developers remember fondly:
CPU read-modify-write of a live framebuffer, feedback effects, deciding
what to draw next frame by inspecting what you drew last frame. The
mental model shift is real: on UMA, the GPU is less "a remote server you
post buffers to" and more "a coprocessor pointed at your arrays."

## Result 3 (negative): `MapOnDefaultTextures` is a trap here

D3D11.3 offers `MapOnDefaultTextures` — mapping DEFAULT-usage textures
directly, which sounds like the UMA dream. We measured it so you don't
have to. On this driver it accepts only `BindFlags = 0` textures (so you
must copy to a bindable texture anyway), and `Unmap` performs cache
maintenance proportional to the resource size: 0.064 ms at 64 KB growing
to 0.867 ms at 8 MB, *every unmap*. It loses to `WRITE_DISCARD` at every
size we tried, and double-buffering does not rescue it. Negative results
rarely get written up; this one cost us an afternoon and is exactly the
kind of thing a datasheet will never tell you.

## Wiring it to the top of the stack

The point of the measurements was product, not benchmarks. The fast path
now runs the whole way up:

- The engine maps the pane's active slot and hands the pointer *into the
  VM* as an external typed array — Dart's `Dart_NewExternalTypedData` over
  the mapped bytes, no copy, no finalizer (D3D owns the memory).
- The Smalltalk `MandelZoom` demo computes a 320×240 frame of palette
  indices into a reused `ByteArray` and hands it over with one
  `directBlit:` — one bulk copy into GPU-shared memory instead of 76,800
  per-pixel drawing commands.
- Two contracts to respect: `WRITE_DISCARD` renames the buffer each frame,
  so the pointer is good for exactly one frame — fetch, fill, present,
  repeat — and the engine unmaps at frame start, before it renders, so the
  frame you present is never the one still being written.

## What we'd tell a friend with a Snapdragon

1. On UMA, `UpdateSubresource` into DEFAULT textures is the *slow* path.
   `DYNAMIC` + `Map(WRITE_DISCARD)` is one flag and one call away and paid
   8× for us.
2. Readback is no longer a sin. Budget it like memcpy, because it is one.
3. Measure `MapOnDefaultTextures` before believing in it. On our driver it
   is strictly worse.
4. The old console tricks are back on the table. Plan your frame around
   shared memory, not around a bus that isn't there.

*Next: the Mandelbrot that stayed slow after all of this — because the
bottleneck was never the GPU.*
