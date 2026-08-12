// WINDARTARM — UMA probe 4: what are the CACHE ATTRIBUTES of mapped memory?
//
// Probe 3 showed the persistent DEFAULT+ROW_MAJOR mapping is SLOWER to write
// than DYNAMIC+WRITE_DISCARD, even though its GPU-side copy is ~free. The
// suspect is write-combined (WC) memory: fast for long sequential runs, awful
// for scattered/strided writes and catastrophic for READS.
//
// This matters for the design: a game that plots sprite SPANS is fine on WC; a
// game that plots scattered single pixels, or that READS BACK its own
// framebuffer (read-modify-write blending, "get pixel"), is not.
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

static const int W = 1024, H = 1024;           // 1 MiB, R8
static const size_t BYTES = (size_t)W * H;

static void seq_write(uint8_t* p, size_t n, uint8_t v) {
  for (size_t i = 0; i < n; i++) p[i] = v;
}
static void strided_write(uint8_t* p, size_t n, uint8_t v) {
  for (size_t i = 0; i < n; i += 64) p[i] = v;
}
static uint64_t seq_read(const uint8_t* p, size_t n) {
  uint64_t s = 0;
  for (size_t i = 0; i < n; i += 8) s += p[i];
  return s;
}

int main() {
  LARGE_INTEGER f; QueryPerformanceFrequency(&f); g_freq = (double)f.QuadPart;
  ComPtr<ID3D11Device> dev; ComPtr<ID3D11Device3> dev3;
  ComPtr<ID3D11DeviceContext> ctx;
  D3D_FEATURE_LEVEL want[] = { D3D_FEATURE_LEVEL_11_1 }, got;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, want, 1,
                               D3D11_SDK_VERSION, &dev, &got, &ctx))) return 1;
  dev.As(&dev3);
  const int iters = 200;

  // --- baseline: ordinary cached heap memory ---
  {
    std::vector<uint8_t> heap(BYTES);
    double t0 = now_ms();
    for (int i = 0; i < iters; i++) seq_write(heap.data(), BYTES, (uint8_t)i);
    double t1 = now_ms();
    for (int i = 0; i < iters; i++) strided_write(heap.data(), BYTES, (uint8_t)i);
    double t2 = now_ms();
    for (int i = 0; i < iters; i++) g_sink += seq_read(heap.data(), BYTES);
    double t3 = now_ms();
    printf("heap (cached)          seq-write %7.4f ms  strided %7.4f ms  read %7.4f ms\n",
           (t1 - t0) / iters, (t2 - t1) / iters, (t3 - t2) / iters);
  }

  // --- DYNAMIC + WRITE_DISCARD (design D1) ---
  {
    D3D11_TEXTURE2D_DESC td = {};
    td.Width = W; td.Height = H; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8_UINT; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DYNAMIC; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    ComPtr<ID3D11Texture2D> tex;
    if (SUCCEEDED(dev->CreateTexture2D(&td, nullptr, &tex))) {
      double sw = 0, st = 0;
      for (int i = 0; i < iters; i++) {
        D3D11_MAPPED_SUBRESOURCE m;
        ctx->Map(tex.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m);
        double a = now_ms(); seq_write((uint8_t*)m.pData, BYTES, (uint8_t)i);
        double b = now_ms(); sw += b - a;
        ctx->Unmap(tex.Get(), 0);
        ctx->Map(tex.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m);
        a = now_ms(); strided_write((uint8_t*)m.pData, BYTES, (uint8_t)i);
        b = now_ms(); st += b - a;
        ctx->Unmap(tex.Get(), 0);
      }
      printf("D1 DYNAMIC/DISCARD     seq-write %7.4f ms  strided %7.4f ms  read %7s\n",
             sw / iters, st / iters, "n/a");
    }
  }

  // --- DEFAULT + ROW_MAJOR + CPU_WRITE, BindFlags=0 (design D2) ---
  {
    D3D11_TEXTURE2D_DESC1 td = {};
    td.Width = W; td.Height = H; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8_UINT; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE | D3D11_CPU_ACCESS_READ;
    td.TextureLayout = D3D11_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D11Texture2D1> t1x;
    HRESULT hr = dev3->CreateTexture2D1(&td, nullptr, &t1x);
    if (FAILED(hr)) {   // retry write-only
      td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
      hr = dev3->CreateTexture2D1(&td, nullptr, &t1x);
    }
    if (SUCCEEDED(hr)) {
      ComPtr<ID3D11Texture2D> tex; t1x.As(&tex);
      double sw = 0, st = 0, rd = 0;
      for (int i = 0; i < iters; i++) {
        D3D11_MAPPED_SUBRESOURCE m;
        if (FAILED(ctx->Map(tex.Get(), 0, D3D11_MAP_WRITE, 0, &m))) break;
        double a = now_ms(); seq_write((uint8_t*)m.pData, BYTES, (uint8_t)i);
        double b = now_ms(); sw += b - a;
        a = now_ms(); strided_write((uint8_t*)m.pData, BYTES, (uint8_t)i);
        b = now_ms(); st += b - a;
        a = now_ms(); g_sink += seq_read((const uint8_t*)m.pData, BYTES);
        b = now_ms(); rd += b - a;
        ctx->Unmap(tex.Get(), 0);
      }
      printf("D2 DEFAULT/ROW_MAJOR   seq-write %7.4f ms  strided %7.4f ms  read %7.4f ms\n",
             sw / iters, st / iters, rd / iters);
    } else {
      printf("D2 DEFAULT/ROW_MAJOR   create failed 0x%08lx\n", hr);
    }
  }

  printf("\n(1 MiB per pass; sink %llu)\n", (unsigned long long)g_sink);
  return 0;
}
