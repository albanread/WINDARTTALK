// WINDARTARM — UMA probe 3: the two candidate direct-framebuffer designs,
// measured end-to-end (plot a full frame + make it sampleable by the GPU).
//
//  D1  DYNAMIC + Map(WRITE_DISCARD), texture is directly sampleable.
//      - no copy, but the pointer MOVES every frame and contents are UNDEFINED
//        after discard => Dart must redraw the whole frame, and cannot hold a
//        stable ExternalTypedData.
//
//  D2  DEFAULT + ROW_MAJOR + CPU_ACCESS_WRITE, BindFlags=0 (probe 2 showed this
//      is the only combination the Adreno driver accepts), then CopyResource
//      into a sampleable SRV texture.
//      - contents PRESERVED, pointer STABLE, pitch TIGHT => Dart holds ONE
//        ExternalTypedData for the pane's lifetime and can draw incrementally,
//        which is what GpIndexedPane already does. Costs one GPU-local copy.
//
// Both are compared against A = today's UpdateSubresource-from-std::vector.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11_4.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>
#include <vector>

using Microsoft::WRL::ComPtr;
static double g_freq = 0.0;
static double now_ms() {
  LARGE_INTEGER c; QueryPerformanceCounter(&c);
  return (double)c.QuadPart * 1000.0 / g_freq;
}
static volatile uint64_t g_sink = 0;

static ComPtr<ID3D11Device> dev;
static ComPtr<ID3D11Device3> dev3;
static ComPtr<ID3D11DeviceContext> ctx;

// Plot work: touch every 64th byte, same in all designs.
static inline void plot(uint8_t* p, size_t bytes, uint8_t v) {
  for (size_t i = 0; i < bytes; i += 64) p[i] = v;
}

static double bench_A(int w, int h, int bpp, DXGI_FORMAT fmt, int iters) {
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
  td.Format = fmt; td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(dev->CreateTexture2D(&td, nullptr, &tex))) return -1;
  std::vector<uint8_t> cpu((size_t)w * h * bpp);
  double t0 = now_ms();
  for (int it = 0; it < iters; it++) {
    plot(cpu.data(), cpu.size(), (uint8_t)it);
    ctx->UpdateSubresource(tex.Get(), 0, nullptr, cpu.data(), (UINT)(w * bpp), 0);
  }
  ctx->Flush();
  double t1 = now_ms(); g_sink += cpu[0];
  return (t1 - t0) / iters;
}

static double bench_D1(int w, int h, int bpp, DXGI_FORMAT fmt, int iters) {
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
  td.Format = fmt; td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DYNAMIC; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(dev->CreateTexture2D(&td, nullptr, &tex))) return -1;
  double t0 = now_ms();
  for (int it = 0; it < iters; it++) {
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ctx->Map(tex.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) return -1;
    for (int y = 0; y < h; y++)
      plot((uint8_t*)m.pData + (size_t)y * m.RowPitch, (size_t)w * bpp, (uint8_t)it);
    ctx->Unmap(tex.Get(), 0);
  }
  ctx->Flush();
  double t1 = now_ms();
  return (t1 - t0) / iters;
}

static double bench_D2(int w, int h, int bpp, DXGI_FORMAT fmt, int iters,
                       double* copy_only) {
  // The CPU-owned, persistent, tightly-packed framebuffer (BindFlags = 0).
  D3D11_TEXTURE2D_DESC1 fd = {};
  fd.Width = w; fd.Height = h; fd.MipLevels = 1; fd.ArraySize = 1;
  fd.Format = fmt; fd.SampleDesc.Count = 1;
  fd.Usage = D3D11_USAGE_DEFAULT; fd.BindFlags = 0;
  fd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  fd.TextureLayout = D3D11_TEXTURE_LAYOUT_ROW_MAJOR;
  ComPtr<ID3D11Texture2D1> fb1;
  if (FAILED(dev3->CreateTexture2D1(&fd, nullptr, &fb1))) return -1;
  ComPtr<ID3D11Texture2D> fb; fb1.As(&fb);

  // The sampleable twin the shaders actually read.
  D3D11_TEXTURE2D_DESC sd = {};
  sd.Width = w; sd.Height = h; sd.MipLevels = 1; sd.ArraySize = 1;
  sd.Format = fmt; sd.SampleDesc.Count = 1;
  sd.Usage = D3D11_USAGE_DEFAULT; sd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  ComPtr<ID3D11Texture2D> srv;
  if (FAILED(dev->CreateTexture2D(&sd, nullptr, &srv))) return -1;

  double t0 = now_ms();
  for (int it = 0; it < iters; it++) {
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ctx->Map(fb.Get(), 0, D3D11_MAP_WRITE, 0, &m))) return -1;
    for (int y = 0; y < h; y++)
      plot((uint8_t*)m.pData + (size_t)y * m.RowPitch, (size_t)w * bpp, (uint8_t)it);
    ctx->Unmap(fb.Get(), 0);
    ctx->CopyResource(srv.Get(), fb.Get());
  }
  ctx->Flush();
  double t1 = now_ms();

  // Isolate the GPU-local copy.
  double c0 = now_ms();
  for (int it = 0; it < iters; it++) ctx->CopyResource(srv.Get(), fb.Get());
  ctx->Flush();
  *copy_only = (now_ms() - c0) / iters;
  return (t1 - t0) / iters;
}

// D3 = D2 but PING-PONG double-buffered. Hypothesis: D2's cost is not the
// memory (probe 4 proved it is fully cached) but the non-discard Map stalling
// on the CopyResource still in flight from the previous frame. Alternating two
// framebuffer textures removes the hazard — and GpIndexedPane is ALREADY
// double-buffered (buffers_[kNumBuffers] / swap_buffers()).
static double bench_D3(int w, int h, int bpp, DXGI_FORMAT fmt, int iters) {
  D3D11_TEXTURE2D_DESC1 fd = {};
  fd.Width = w; fd.Height = h; fd.MipLevels = 1; fd.ArraySize = 1;
  fd.Format = fmt; fd.SampleDesc.Count = 1;
  fd.Usage = D3D11_USAGE_DEFAULT; fd.BindFlags = 0;
  fd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  fd.TextureLayout = D3D11_TEXTURE_LAYOUT_ROW_MAJOR;
  ComPtr<ID3D11Texture2D> fb[2];
  for (int i = 0; i < 2; i++) {
    ComPtr<ID3D11Texture2D1> t1x;
    if (FAILED(dev3->CreateTexture2D1(&fd, nullptr, &t1x))) return -1;
    t1x.As(&fb[i]);
  }
  D3D11_TEXTURE2D_DESC sd = {};
  sd.Width = w; sd.Height = h; sd.MipLevels = 1; sd.ArraySize = 1;
  sd.Format = fmt; sd.SampleDesc.Count = 1;
  sd.Usage = D3D11_USAGE_DEFAULT; sd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  ComPtr<ID3D11Texture2D> srv;
  if (FAILED(dev->CreateTexture2D(&sd, nullptr, &srv))) return -1;

  double t0 = now_ms();
  for (int it = 0; it < iters; it++) {
    ID3D11Texture2D* cur = fb[it & 1].Get();
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ctx->Map(cur, 0, D3D11_MAP_WRITE, 0, &m))) return -1;
    for (int y = 0; y < h; y++)
      plot((uint8_t*)m.pData + (size_t)y * m.RowPitch, (size_t)w * bpp, (uint8_t)it);
    ctx->Unmap(cur, 0);
    ctx->CopyResource(srv.Get(), cur);
  }
  ctx->Flush();
  return (now_ms() - t0) / iters;
}

int main() {
  LARGE_INTEGER f; QueryPerformanceFrequency(&f); g_freq = (double)f.QuadPart;
  D3D_FEATURE_LEVEL want[] = { D3D_FEATURE_LEVEL_11_1 }, got;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, want, 1,
                               D3D11_SDK_VERSION, &dev, &got, &ctx))) return 1;
  dev.As(&dev3);

  struct Case { const char* label; int w, h, bpp; DXGI_FORMAT fmt; };
  Case cases[] = {
    { "indexed  320x200 R8",   320,  200, 1, DXGI_FORMAT_R8_UINT },
    { "indexed  640x400 R8",   640,  400, 1, DXGI_FORMAT_R8_UINT },
    { "rgba     640x400",      640,  400, 4, DXGI_FORMAT_B8G8R8A8_UNORM },
    { "rgba    1920x1080",    1920, 1080, 4, DXGI_FORMAT_B8G8R8A8_UNORM },
  };
  printf("%-20s %11s %11s %11s %11s\n", "case", "A:today", "D1:discard", "D2:persist", "D3:persist2");
  for (const Case& c : cases) {
    int iters = (c.w > 1000) ? 200 : 500;
    double copy = 0;
    double a = bench_A(c.w, c.h, c.bpp, c.fmt, iters);
    double d1 = bench_D1(c.w, c.h, c.bpp, c.fmt, iters);
    double d2 = bench_D2(c.w, c.h, c.bpp, c.fmt, iters, &copy);
    double d3 = bench_D3(c.w, c.h, c.bpp, c.fmt, iters);
    printf("%-20s %8.4f ms %8.4f ms %8.4f ms %8.4f ms   D1=%.1fx D3=%.1fx (copy %.4f)\n",
           c.label, a, d1, d2, d3, (d1 > 0) ? a / d1 : 0,
           (d3 > 0) ? a / d3 : 0, copy);
  }
  printf("\nsink %llu\n", (unsigned long long)g_sink);
  return 0;
}
