# Unified memory on Snapdragon — measured, and what the game pane should do

**Adreno X1-45, Snapdragon X (Oryon), D3D11 feature level 11_1.** All numbers
measured on this machine with `port-arm64/probes/uma_probe*.cpp`. This note
exists because the SoC shares physical DRAM between CPU and GPU, so the
CPU→GPU *transfer* the engine currently pays for need not exist.

## 0. The headline

Today `GpIndexedPane::upload()` (`gp_engine_d3d.cpp:446`) does
`UpdateSubresource` from a CPU-side `std::vector` on every dirty frame — a full
copy of the framebuffer. Direct-framebuffer mode (`Win_gpBackbuffer`) is
**deferred and returns null** (S6b).

Plotting straight into mapped GPU memory instead is **5.7×–19.4× faster**, and
it deletes the CPU-side staging buffer entirely. On this hardware the deferred
feature is not a nicety — it is the single biggest win available to the pane.

## 1. What the hardware reports

```
adapter            : Qualcomm(R) Adreno(TM) X1-45 GPU
  DedicatedVideoMem: 128 MB          <- a carve-out, not a separate pool
  SharedSystemMem  : 16163 MB        <- the real story
  feature level    : 11_1
  UMA              : YES
  MapOnDefaultTex  : YES             <- but see §3, it is a trap
  TileBasedDeferred: YES             <- Adreno is a TBDR; see §5
```

## 2. Upload paths, measured

Each path does the *same* plotting work, so the comparison is architectural:
A writes a CPU buffer then copies it; C plots straight into GPU-visible memory.

| case | A: `UpdateSubresource` (today) | B: Map + memcpy | **C: plot into mapped memory** | C vs A |
|---|---|---|---|---|
| indexed 320×200 R8 | 0.0489 ms | 0.0047 ms | **0.0026 ms** | **19.2×** |
| indexed 640×400 R8 | 0.0930 ms | 0.0118 ms | **0.0051 ms** | **18.4×** |
| rgba 640×400 | 0.2737 ms | 0.0399 ms | **0.0148 ms** | **18.5×** |
| rgba 1920×1080 | 0.8185 ms | 0.4491 ms | **0.1127 ms** | **7.3×** |

Two separable wins:

- **A → B is ~8×** and needs **no Dart-side change at all**: just stop using
  `UpdateSubresource` on a `DEFAULT` texture and use `DYNAMIC` +
  `Map(WRITE_DISCARD)`. `UpdateSubresource` makes the driver stage internally;
  on UMA that staging is pure waste.
- **B → C is a further ~2.3×** and is the actual direct-framebuffer feature:
  hand Dart the mapped pointer so there is no CPU staging buffer at all.

Readback (`gpsnap`: `CopyResource` → `STAGING` → `Map(READ)`) is **0.144 ms at
640×400, 0.561 ms at 1080p**. On a discrete GPU this is a PCIe round trip with a
pipeline stall costing milliseconds; here it is cheap enough to do **per frame**,
not just for snapshots.

## 3. `MapOnDefaultTextures` — advertised, and a trap

The cap says YES, which would be the prize: a texture that is renderable *and*
CPU-writable in place, with **persistent** contents (no `WRITE_DISCARD`
renaming), so the pane could keep drawing incrementally as `GpIndexedPane`
already does. Findings, in order:

1. Legacy `CreateTexture2D` + `Map` → `E_INVALIDARG`. It requires the D3D11.3
   path: `ID3D11Device3::CreateTexture2D1` with an explicit
   `D3D11_TEXTURE_LAYOUT_ROW_MAJOR`.
2. Even then, **any bind flag fails**. `SHADER_RESOURCE`, `RENDER_TARGET`, or
   both → `E_INVALIDARG`, in both `ROW_MAJOR` and `64K_STANDARD_SWIZZLE`.
   Only `BindFlags = 0` is accepted.
3. With `BindFlags = 0` the properties are genuinely ideal:
   - contents **PRESERVED** across Map/Unmap
   - `RowPitch` **tight** (640 for R8, 2560 for BGRA) — a flat framebuffer,
     exactly the shape `Dart_NewExternalTypedData` wants
   - pointer **stable** across Maps — Dart could hold ONE external typed data
     for the pane's lifetime
   - bare Map/Unmap ≈ 0.002 ms

But end-to-end it loses badly, and this is the important negative result:

| case | A: today | **D1: DYNAMIC+DISCARD** | D2: persistent | D3: persistent, double-buffered |
|---|---|---|---|---|
| indexed 320×200 | 0.0495 | **0.0026** | 0.0955 | 0.0635 |
| indexed 640×400 | 0.0857 | **0.0065** | 0.1181 | 0.1354 |
| rgba 640×400 | 0.1787 | **0.0313** | 0.1299 | 0.1592 |
| rgba 1920×1080 | 0.9290 | **0.1146** | 0.5439 | 0.8666 |

### Why — and the two hypotheses that were wrong

- **Not write-combined memory.** Probe 4 compared the mapped pointers against
  an ordinary heap allocation, 1 MiB per pass:

  | memory | seq-write | strided write | **read** |
  |---|---|---|---|
  | heap (cached) | 0.0154 ms | 0.0124 ms | 0.0598 ms |
  | D1 `DYNAMIC` mapped | 0.0164 ms | 0.0120 ms | — |
  | D2 `DEFAULT/ROW_MAJOR` mapped | 0.0162 ms | 0.0124 ms | **0.0592 ms** |

  Mapped GPU memory is **fully cached and reads at normal RAM speed**. On a
  discrete GPU that memory is write-combined and reads are 10–100× slower, which
  makes read-modify-write blending impossible; here it is free. **This is the
  real unified-memory dividend and it should shape the pane's API** (§4).
- **Not a pipeline stall on the pending copy.** Ping-pong double-buffering (D3)
  did not fix it either.

What remains: the cost tracks **size**, not frame count — 0.064 ms at 64 KB,
0.867 ms at 8 MB. The `CopyResource` is ~0.0005 ms regardless. So the O(size)
step is `Unmap` performing **cache maintenance** — cleaning the CPU cache lines
so the GPU sees the writes. That is precisely the price of the coherency that
makes §4's cheap reads possible, and `WRITE_DISCARD` avoids it by handing back a
fresh pool buffer instead of publishing an existing one.

**Verdict: use D1. Do not build on `MapOnDefaultTextures`.**

## 4. Recommended design for AS5

**Tier 1 — internal only, no protocol change. ✅ DONE 2026-08-12.**
`MakeIndexTex` now creates the index slots `DYNAMIC` + `CPU_ACCESS_WRITE`, and
`GpIndexedPane::upload()` uses `Map(WRITE_DISCARD)` + a row-pitch-aware copy
instead of `UpdateSubresource`. `WRITE_DISCARD` is sound here because the whole
slot is rewritten from `buffers_[i]`, the CPU-side source of truth — the
discarded contents are never read back. A failed `Map` leaves `dirty_` set so
the slot retries next frame rather than silently showing a stale image.

**Verified identical, not just faster:** `tiletest` (a static pattern, so
deterministic) is **byte-for-byte identical** before and after —
`game_tiletest.png` and `game_tiletest_present.png` both match on SHA-256.
`coindash` differs only because it is animated and the capture lands on a
different frame each run (`DIST 23` vs `DIST 24`; frame counts across runs have
been 80/81/83/85); its composition is unchanged.

**Scope correction:** sprite frames stay `IMMUTABLE` — they are written once at
definition time, so there is nothing to win and `IMMUTABLE` lets the driver
place them optimally. The **constant buffers were deliberately left alone**: the
~8× was measured on a full framebuffer texture, and a 16–64 byte constant buffer
is not the same case — `UpdateSubresource` is idiomatic and cheap there, so
changing it would add risk for no measured benefit. (An earlier draft of this
note listed those sites; that was over-broad.)

**Tier 2 — direct-framebuffer mode (the deferred S6b feature). ✅ DONE 2026-08-12.**

Scoping correction found on contact: this was **not** "one stubbed function".
Direct mode was wholly absent — `direct_` was never set, `direct_stride()`
returned a hardcoded 0, and **`gpdpal`/`gpdblit` were not in the verb table at
all**, which is why a direct game's 256 startup palette ops vanished silently.

What Tier 1 bought: the index slots became `DYNAMIC` and therefore mappable, so
direct mode did not need a parallel resource path — it reuses the pane's own
texture and palette. Implemented as:

- `GpIndexedPane::MapDirect(&pitch)` / `UnmapDirect()` — map the **active** slot
  `WRITE_DISCARD`, remember which slot was mapped (`active_` may move), and on
  unmap clear that slot's `dirty_` flag so `upload()` cannot overwrite what Dart
  just wrote with stale `buffers_[]` content.
- `GpEngine::begin_frame()` unmaps at the frame boundary; `render()` unmaps
  defensively — never draw from a mapped resource.
- `gpdpal` folded into the `gppal` case: direct mode shares the indexed
  palette (same 8-bit index space, same lookup shader), so it is the same
  operation under a second name.
- `Win_gpBackbuffer()` returns `Dart_NewExternalTypedData(kUint8, ptr,
  pitch * world_h)`. Length spans whole rows **including padding**, so
  `y*stride + x` is always in bounds; `direct_stride()` (`gpStat()[6]`) now
  reports the real `RowPitch` instead of 0. No finalizer — the memory is D3D's,
  released by Unmap, never by Dart.

**Verified:** MandelZoom renders the seahorse valley
(`shots/stgame_MandelZoom.png`, 19 KB vs the previous 895-byte black frame),
and `tcl/test_c5_game.tcl` — the battery's only failure — now passes.

Original design sketch, retained because the one-frame contract still governs:

- Map at frame start, hand the pointer to Dart, Unmap before the draw. D3D11
  forbids holding a Map across a Draw, so the buffer must be surrendered — this
  fits the existing "one `gpApply(cmds)` per frame, applied atomically" wire.
- `WRITE_DISCARD` renames the allocation, so **the pointer changes every frame**
  and previous contents are undefined. The Dart side must therefore treat it as
  a write-only, full-redraw surface, and must not retain it across frames.
  Enforce with a frame token: the external typed data is finalised/invalidated at
  Unmap, and a stale handle fails closed (the same discipline the ticket-based
  callbacks already use).
- Games that need persistence keep their own logical buffer and blit — which is
  what they do today anyway.

**Tier 3 — exploit cheap coherent reads.** Because mapped memory reads at full
cached-RAM speed (§3), things that are normally forbidden on a GPU become
practical: per-frame `gpsnap` readback (0.14 ms at 640×400), CPU-side
read-modify-write effects, and CPU/GPU hybrid passes. This is the capability
that genuinely does not exist on the x64/discrete-GPU target, and it is worth
designing *for* rather than merely porting *to*.

## 4a. Two shims that made the Smalltalk games render (2026-08-12)

Neither is unified-memory work, but both were found by wiring `gpApply`'s return
value to a log — **both call sites discarded it**, so every rejected op failed
silently and showed up only as something missing on screen.

### MSL → HLSL dialect shim (`GpShaderPane::compile`)

The world was written against Metal — `GamePane >> shader:` even names its
parameter `mslSource`. `D3DCompile` rejected it outright
(`X3004: undeclared identifier 'fract'`), so **layer 0 never compiled** and
every shader-backed game ran on a black field. Galaxigans' own comment confirms
the direction of travel: *"Translated from the original's HLSL … Metal spelling:
frac->fract, lerp->mix"* — so the shim simply reverses a documented transform.

Two passes, both no-ops on input that is already HLSL:
- **Names:** `fract→frac`, `mix→lerp`, `inversesqrt→rsqrt`, `dfdx/dfdy→ddx/ddy`,
  2-arg `atan→atan2` (arity-checked, since 1-arg `atan` is valid in both),
  `discard_fragment→discard`. Only rewritten when the identifier is followed by
  `(` — a *call* — so a variable innocently named `mix` is not clobbered into
  shadowing the intrinsic.
- **`mod` is deliberately NOT mapped to `fmod`.** GLSL/MSL `mod` is floor-based,
  HLSL `fmod` truncates, so they disagree in sign for negative operands — a
  silent wrong-pixel bug. It maps to a `gpModGl` helper carrying the GLSL
  definition.
- **Entry point:** `fragment float4 fmain(VOut in [[stage_in]], constant
  Uniforms& u [[buffer(0)]])` becomes `float4 fmain(GVOut gpIn) : SV_Target`,
  MSL `[[attributes]]` are stripped, the uniform-struct prefix is dropped
  (`u.time` → the header's global `time`), and the stage_in parameter is renamed
  because MSL bodies call it `in`, which is a parameter-modifier keyword in HLSL.

### Sprite id mapping (`cocoa.dart`)

`gpsprite`/`gpspawn` do not *take* an id — `sprites->define()` and
`sprites->place()` **assign** the next sequential one and the verb merely
asserts the caller predicted it. The Dart demos define 0,1,2,… in call order so
they match; a Smalltalk game picks its own ids, so the first define failed
(`gpsprite: id out of sequence`), no instance was ever created, and every
placement then reported `gpplace: bad instance` — no sprites at all.

Fixed by mirroring the engine's counters in `cocoa.dart` and translating ST id →
engine id, with **separate definition and instance maps** (they are separate
namespaces engine-side, and ST uses one id for both). `gpspritepal`/`gpframe`
map through the definition table, `gpplace`/`gphide` through the instance table,
and `stGpReset()` clears both so the next game does not inherit the previous
one's numbering.

**Result: Galaxigans renders complete** — shader cosmos, full sprite fleet,
seven-segment HUD, indexed particle layer, XAudio2 SFX, zero `GPERR`.

## 5. Adreno is a tile-based deferred renderer

`TileBasedDeferredRenderer: YES`. Consequences for the pane, to verify in AS5:

- **Always fully clear a render target** at the start of a pass
  (`ClearRenderTargetView`) rather than partially overwriting it. On a TBDR a
  clear is free — it just marks the tile — whereas a partial write forces the
  previous contents to be *loaded* into tile memory.
- **Avoid mid-pass reads of the target you are writing.** The five-layer
  composite and the compute blitter should be checked for render-target
  ping-ponging that would force tile flushes.
- The per-scanline "copper" palette trick is a pixel-shader constant lookup, so
  it should be unaffected — confirm.

## 6. Reproducing

Probes are in `port-arm64/probes/`, each self-contained:
`uma_probe.cpp` (caps + upload paths + readback), `uma_probe2.cpp`
(`MapOnDefaultTextures` matrix), `uma_probe3.cpp` (end-to-end designs),
`uma_probe4.cpp` (cache attributes). Build:

```
cl /nologo /O2 /EHsc /std:c++14 uma_probe.cpp /link d3d11.lib dxgi.lib
```
