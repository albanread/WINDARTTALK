// WINDARTARM — Snapdragon/Adreno unified-memory probe for the D3D11 game pane.
//
// Question: on this SoC the GPU shares physical DRAM with the CPU, so a CPU
// write into a GPU-visible buffer should need NO transfer. The engine today
// (gp_engine_d3d.cpp:446) uploads the indexed framebuffer with
// UpdateSubresource from a CPU-side std::vector every dirty frame — a full
// copy. Direct-framebuffer mode (Win_gpBackbuffer) is deferred and returns null.
//
// Measure: (1) does D3D11 report UMA? (2) how do the realistic upload paths
// compare at the game pane's actual sizes? (3) what does gpsnap-style readback
// cost? Numbers decide whether AS5 should implement the direct framebuffer.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>

using Microsoft::WRL::ComPtr;

static double g_freq = 0.0;
static double now_ms() {
  LARGE_INTEGER c; QueryPerformanceCounter(&c);
  return (double)c.QuadPart * 1000.0 / g_freq;
}

static ComPtr<ID3D11Device> dev;
static ComPtr<ID3D11DeviceContext> ctx;

// Keep a sink so the optimiser cannot delete the pixel writes.
static volatile uint64_t g_sink = 0;

struct Result { const char* name; double ms; double mbps; };

// --- path A: today's engine — DEFAULT texture + UpdateSubresource ------------
static double bench_updatesubresource(int w, int h, int bpp, DXGI_FORMAT fmt,
                                      int iters) {
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
  td.Format = fmt; td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(dev->CreateTexture2D(&td, nullptr, &tex))) return -1.0;

  std::vector<uint8_t> cpu((size_t)w * h * bpp);
  double t0 = now_ms();
  for (int it = 0; it < iters; it++) {
    // The game plots into its CPU buffer...
    uint8_t v = (uint8_t)it;
    for (size_t i = 0; i < cpu.size(); i += 64) cpu[i] = v;
    // ...then the engine copies the whole thing to the GPU.
    ctx->UpdateSubresource(tex.Get(), 0, nullptr, cpu.data(), (UINT)(w * bpp), 0);
  }
  ctx->Flush();
  double t1 = now_ms();
  g_sink += cpu[0];
  return (t1 - t0) / iters;
}

// --- path B: DYNAMIC texture + Map(WRITE_DISCARD) + memcpy from a CPU buffer -
static double bench_map_memcpy(int w, int h, int bpp, DXGI_FORMAT fmt,
                               int iters) {
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
  td.Format = fmt; td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DYNAMIC;
  td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(dev->CreateTexture2D(&td, nullptr, &tex))) return -1.0;

  std::vector<uint8_t> cpu((size_t)w * h * bpp);
  double t0 = now_ms();
  for (int it = 0; it < iters; it++) {
    uint8_t v = (uint8_t)it;
    for (size_t i = 0; i < cpu.size(); i += 64) cpu[i] = v;
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ctx->Map(tex.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return -1.0;
    const uint8_t* src = cpu.data();
    uint8_t* dst = (uint8_t*)m.pData;
    for (int y = 0; y < h; y++) memcpy(dst + (size_t)y * m.RowPitch,
                                       src + (size_t)y * w * bpp, (size_t)w * bpp);
    ctx->Unmap(tex.Get(), 0);
  }
  ctx->Flush();
  double t1 = now_ms();
  g_sink += cpu[0];
  return (t1 - t0) / iters;
}

// --- path C: THE UMA PATH — plot straight into the mapped GPU pointer -------
// This is what direct-framebuffer mode would give Dart via ExternalTypedData:
// no CPU-side staging buffer at all, no copy.
static double bench_map_direct(int w, int h, int bpp, DXGI_FORMAT fmt,
                               int iters) {
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
  td.Format = fmt; td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DYNAMIC;
  td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(dev->CreateTexture2D(&td, nullptr, &tex))) return -1.0;

  double t0 = now_ms();
  for (int it = 0; it < iters; it++) {
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ctx->Map(tex.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return -1.0;
    uint8_t* dst = (uint8_t*)m.pData;
    uint8_t v = (uint8_t)it;
    // Identical plotting work as paths A/B, but landing in GPU memory directly.
    for (int y = 0; y < h; y++) {
      uint8_t* row = dst + (size_t)y * m.RowPitch;
      for (int x = 0; x < w * bpp; x += 64) row[x] = v;
    }
    ctx->Unmap(tex.Get(), 0);
  }
  ctx->Flush();
  double t1 = now_ms();
  return (t1 - t0) / iters;
}

// --- readback: what gpsnap does (CopyResource -> STAGING -> Map(READ)) ------
static double bench_readback(int w, int h, int iters) {
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  ComPtr<ID3D11Texture2D> off;
  if (FAILED(dev->CreateTexture2D(&td, nullptr, &off))) return -1.0;

  D3D11_TEXTURE2D_DESC sd = td;
  sd.Usage = D3D11_USAGE_STAGING;
  sd.BindFlags = 0;
  sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> stg;
  if (FAILED(dev->CreateTexture2D(&sd, nullptr, &stg))) return -1.0;

  double t0 = now_ms();
  for (int it = 0; it < iters; it++) {
    ctx->CopyResource(stg.Get(), off.Get());
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ctx->Map(stg.Get(), 0, D3D11_MAP_READ, 0, &m))) return -1.0;
    g_sink += ((uint8_t*)m.pData)[0];
    ctx->Unmap(stg.Get(), 0);
  }
  double t1 = now_ms();
  return (t1 - t0) / iters;
}

int main() {
  LARGE_INTEGER f; QueryPerformanceFrequency(&f); g_freq = (double)f.QuadPart;

  // ---- adapter ----
  ComPtr<IDXGIFactory1> fac;
  CreateDXGIFactory1(IID_PPV_ARGS(&fac));
  ComPtr<IDXGIAdapter1> ad;
  fac->EnumAdapters1(0, &ad);
  DXGI_ADAPTER_DESC1 adesc = {};
  if (ad) ad->GetDesc1(&adesc);
  printf("adapter            : %ls\n", adesc.Description);
  printf("  DedicatedVideoMem: %llu MB\n",
         (unsigned long long)(adesc.DedicatedVideoMemory / (1024 * 1024)));
  printf("  DedicatedSysMem  : %llu MB\n",
         (unsigned long long)(adesc.DedicatedSystemMemory / (1024 * 1024)));
  printf("  SharedSystemMem  : %llu MB\n",
         (unsigned long long)(adesc.SharedSystemMemory / (1024 * 1024)));

  D3D_FEATURE_LEVEL want[] = { D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_11_1,
                               D3D_FEATURE_LEVEL_11_0 };
  D3D_FEATURE_LEVEL got;
  HRESULT hr = D3D11CreateDevice(ad.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, want, 3,
                                 D3D11_SDK_VERSION, &dev, &got, &ctx);
  if (FAILED(hr)) { printf("D3D11CreateDevice failed 0x%08lx\n", hr); return 1; }
  printf("  feature level    : 0x%04x\n", (unsigned)got);

  // ---- THE question: does the driver advertise unified memory? ----
  D3D11_FEATURE_DATA_D3D11_OPTIONS2 o2 = {};
  if (SUCCEEDED(dev->CheckFeatureSupport(D3D11_FEATURE_D3D11_OPTIONS2, &o2,
                                         sizeof(o2)))) {
    printf("  UMA              : %s\n",
           o2.UnifiedMemoryArchitecture ? "YES" : "no");
    printf("  MapOnDefaultTex  : %s\n",
           o2.MapOnDefaultTextures ? "YES" : "no");
  } else {
    printf("  UMA              : (OPTIONS2 unsupported)\n");
  }
  D3D11_FEATURE_DATA_ARCHITECTURE_INFO ai = {};
  if (SUCCEEDED(dev->CheckFeatureSupport(D3D11_FEATURE_ARCHITECTURE_INFO, &ai,
                                         sizeof(ai)))) {
    printf("  TileBasedDeferred: %s\n",
           ai.TileBasedDeferredRenderer ? "YES" : "no");
  }
  D3D11_FEATURE_DATA_D3D11_OPTIONS o1 = {};
  if (SUCCEEDED(dev->CheckFeatureSupport(D3D11_FEATURE_D3D11_OPTIONS, &o1,
                                         sizeof(o1)))) {
    printf("  MapNoOverwriteOnDynamicTexture: %s\n",
           o1.MapNoOverwriteOnDynamicBufferSRV ? "YES(buf SRV)" : "no(buf SRV)");
  }

  // ---- upload paths at the game pane's real sizes ----
  struct Case { const char* label; int w, h, bpp; DXGI_FORMAT fmt; };
  Case cases[] = {
    { "indexed 320x200 R8",   320,  200, 1, DXGI_FORMAT_R8_UINT },
    { "indexed 640x400 R8",   640,  400, 1, DXGI_FORMAT_R8_UINT },
    { "rgba 640x400 BGRA",    640,  400, 4, DXGI_FORMAT_B8G8R8A8_UNORM },
    { "rgba 1920x1080 BGRA", 1920, 1080, 4, DXGI_FORMAT_B8G8R8A8_UNORM },
  };
  const int iters = 300;
  printf("\n%-22s %12s %12s %12s   %s\n", "case", "A:UpdateSub", "B:Map+memcpy",
         "C:Map direct", "C vs A");
  for (const Case& c : cases) {
    double a = bench_updatesubresource(c.w, c.h, c.bpp, c.fmt, iters);
    double b = bench_map_memcpy(c.w, c.h, c.bpp, c.fmt, iters);
    double d = bench_map_direct(c.w, c.h, c.bpp, c.fmt, iters);
    printf("%-22s %9.4f ms %9.4f ms %9.4f ms   %5.2fx\n", c.label, a, b, d,
           (d > 0.0) ? a / d : 0.0);
  }

  printf("\nreadback (gpsnap: CopyResource -> STAGING -> Map(READ)):\n");
  printf("  640x400   : %.4f ms\n", bench_readback(640, 400, 200));
  printf("  1920x1080 : %.4f ms\n", bench_readback(1920, 1080, 100));

  printf("\nsink %llu\n", (unsigned long long)g_sink);
  return 0;
}
