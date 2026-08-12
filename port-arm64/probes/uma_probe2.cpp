// WINDARTARM — UMA probe 2: can we map a DEFAULT (renderable) texture?
//
// Probe 1 reported MapOnDefaultTextures=YES on the Adreno X1-45. If that works
// for our formats it is the prize: a texture that is BOTH GPU-renderable AND
// CPU-writable in place, with PERSISTENT contents — no WRITE_DISCARD renaming,
// so the game can draw incrementally (the classic "dirty rectangle" style the
// indexed pane already uses) instead of being forced into a full redraw.
//
// Also checks: is the mapped pointer stable across frames (can Dart hold one
// ExternalTypedData for the pane's lifetime?), and what does the row pitch look
// like (does it match width, i.e. can Dart treat it as a flat framebuffer?).
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>

using Microsoft::WRL::ComPtr;
static double g_freq = 0.0;
static double now_ms() {
  LARGE_INTEGER c; QueryPerformanceCounter(&c);
  return (double)c.QuadPart * 1000.0 / g_freq;
}
static volatile uint64_t g_sink = 0;

static const char* fmt_name(DXGI_FORMAT f) {
  switch (f) {
    case DXGI_FORMAT_R8_UINT: return "R8_UINT";
    case DXGI_FORMAT_B8G8R8A8_UNORM: return "BGRA8";
    default: return "?";
  }
}

int main() {
  LARGE_INTEGER f; QueryPerformanceFrequency(&f); g_freq = (double)f.QuadPart;

  ComPtr<ID3D11Device> dev; ComPtr<ID3D11DeviceContext> ctx;
  D3D_FEATURE_LEVEL want[] = { D3D_FEATURE_LEVEL_11_1 }, got;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, want, 1,
                               D3D11_SDK_VERSION, &dev, &got, &ctx))) {
    printf("no device\n"); return 1;
  }
  ComPtr<ID3D11Device3> dev3;
  bool has_dev3 = SUCCEEDED(dev.As(&dev3));
  printf("ID3D11Device3: %s\n\n", has_dev3 ? "yes" : "NO");

  struct Case { int w, h; DXGI_FORMAT fmt; UINT bind; const char* what; };
  Case cases[] = {
    { 640, 400, DXGI_FORMAT_R8_UINT,        D3D11_BIND_SHADER_RESOURCE, "indexed SRV" },
    { 640, 400, DXGI_FORMAT_B8G8R8A8_UNORM, D3D11_BIND_SHADER_RESOURCE, "rgba SRV" },
    { 640, 400, DXGI_FORMAT_B8G8R8A8_UNORM,
      D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET, "rgba SRV+RTV" },
    { 640, 400, DXGI_FORMAT_R8_UINT,        0, "indexed NO bind flags" },
    { 640, 400, DXGI_FORMAT_B8G8R8A8_UNORM, 0, "rgba NO bind flags" },
  };

  for (const Case& c : cases) {
    printf("--- %s  %dx%d %s ---\n", c.what, c.w, c.h, fmt_name(c.fmt));
    // MapOnDefaultTextures requires the D3D11.3 entry point AND an explicit
    // ROW_MAJOR layout — the legacy CreateTexture2D path returns E_INVALIDARG
    // from Map() no matter what the cap says.
    D3D11_TEXTURE2D_DESC1 td = {};
    td.Width = c.w; td.Height = c.h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = c.fmt; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = c.bind;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;   // the UMA ask
    td.TextureLayout = D3D11_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D11Texture2D1> tex1;
    HRESULT hr = dev3 ? dev3->CreateTexture2D1(&td, nullptr, &tex1) : E_NOINTERFACE;
    if (FAILED(hr)) {
      printf("  CreateTexture2D1(DEFAULT+CPU_WRITE+ROW_MAJOR) FAILED 0x%08lx\n",
             hr);
      // Fall back: is 64K_STANDARD_SWIZZLE accepted instead?
      td.TextureLayout = D3D11_TEXTURE_LAYOUT_64K_STANDARD_SWIZZLE;
      hr = dev3 ? dev3->CreateTexture2D1(&td, nullptr, &tex1) : E_NOINTERFACE;
      printf("  ...64K_STANDARD_SWIZZLE            : %s\n\n",
             SUCCEEDED(hr) ? "ok" : "also failed");
      if (FAILED(hr)) continue;
    } else {
      printf("  CreateTexture2D1(ROW_MAJOR): ok\n");
    }
    ComPtr<ID3D11Texture2D> tex;
    tex1.As(&tex);

    // Map it. WRITE (not WRITE_DISCARD) — we want the contents PRESERVED.
    void* first_ptr = nullptr;
    UINT first_pitch = 0;
    bool stable = true;
    for (int it = 0; it < 4; it++) {
      D3D11_MAPPED_SUBRESOURCE m;
      hr = ctx->Map(tex.Get(), 0, D3D11_MAP_WRITE, 0, &m);
      if (FAILED(hr)) {
        printf("  Map(D3D11_MAP_WRITE) FAILED 0x%08lx\n", hr);
        first_ptr = nullptr;
        break;
      }
      if (it == 0) { first_ptr = m.pData; first_pitch = m.RowPitch; }
      else if (m.pData != first_ptr) { stable = false; }
      // write a marker in frame 0, read it back in later frames -> persistence
      uint8_t* p = (uint8_t*)m.pData;
      if (it == 0) { p[0] = 0xAB; p[m.RowPitch] = 0xCD; }
      else if (it == 1) {
        printf("  persistence     : [0]=0x%02X [pitch]=0x%02X  -> %s\n",
               p[0], p[m.RowPitch],
               (p[0] == 0xAB && p[m.RowPitch] == 0xCD) ? "PRESERVED"
                                                       : "lost (renamed)");
      }
      ctx->Unmap(tex.Get(), 0);
    }
    if (first_ptr != nullptr) {
      printf("  RowPitch        : %u  (width*bpp = %d) -> %s\n", first_pitch,
             c.w * (c.fmt == DXGI_FORMAT_R8_UINT ? 1 : 4),
             (first_pitch == (UINT)(c.w * (c.fmt == DXGI_FORMAT_R8_UINT ? 1 : 4)))
                 ? "TIGHT (flat framebuffer)" : "padded");
      printf("  pointer stable  : %s\n", stable ? "YES (same address each Map)"
                                                : "no (moves)");

      // Cost of the map/unmap bracket itself (the per-frame overhead Dart pays).
      const int iters = 2000;
      double t0 = now_ms();
      for (int it = 0; it < iters; it++) {
        D3D11_MAPPED_SUBRESOURCE m;
        if (FAILED(ctx->Map(tex.Get(), 0, D3D11_MAP_WRITE, 0, &m))) break;
        g_sink += ((uint8_t*)m.pData)[0];
        ctx->Unmap(tex.Get(), 0);
      }
      double t1 = now_ms();
      printf("  Map/Unmap cost  : %.5f ms per frame\n", (t1 - t0) / iters);
    }
    printf("\n");
  }

  printf("sink %llu\n", (unsigned long long)g_sink);
  return 0;
}
