// fp_probe.cpp - WINDARTARM AS7: how does a Windows/arm64 MSVC build read x29?
//
// vm/globals.h's COPY_FP_REGISTER falls through to the x64 branch on arm64,
// which returns the STACK pointer ("we don't have the asm equivalent"). The
// profiler's native walker then reads fp[0]/fp[1] as caller-fp/return-address
// off the top of the stack, gets garbage, and stops after one frame - so every
// crash dump on this port shows a single line.
//
// MSVC has no inline asm on arm64. Two candidates:
//   A. _AddressOfReturnAddress() - an intrinsic; on Windows/arm64 x29 points at
//      the saved {x29,x30} pair, so the address of the return slot is x29+8.
//   B. RtlCaptureContext() - a real Win32 call filling a ~900-byte CONTEXT
//      whose .Fp field is x29 outright.
//
// This probe answers three questions with numbers:
//   1. Do A and B agree, in the same frame? (If so, A is exact and free.)
//   2. Does the resulting fp actually WALK - do we recover the call chain?
//   3. What does each cost, per call?
//
//   cl /O2 /EHsc fp_probe.cpp
#include <windows.h>
#include <intrin.h>
#include <stdio.h>
#include <stdint.h>

typedef uintptr_t uword;

// The two candidates, written exactly as the VM would use them.
static inline uword FpViaIntrinsic() {
  return reinterpret_cast<uword>(_AddressOfReturnAddress()) - 8;
}

static inline uword FpViaContext() {
  CONTEXT ctx;
  RtlCaptureContext(&ctx);
  return static_cast<uword>(ctx.Fp);
}

// --- 1. do they agree? -------------------------------------------------------
// Both are read in ONE frame so they describe the same activation.
__declspec(noinline) void Agreement() {
  uword a = FpViaIntrinsic();
  uword b = FpViaContext();
  printf("  _AddressOfReturnAddress()-8 = 0x%llx\n", (unsigned long long)a);
  printf("  RtlCaptureContext().Fp      = 0x%llx\n", (unsigned long long)b);
  printf("  agree: %s   (delta %lld)\n", a == b ? "YES" : "NO",
         (long long)(a - b));
}

// --- 2. does it walk? --------------------------------------------------------
// The VM's ProfilerNativeStackWalker does exactly this: fp[0] is the caller's
// fp, fp[1] the return address, repeat while the fp climbs.
static int WalkFrom(uword fp, uword lo, uword hi, const char* label) {
  int depth = 0;
  uword prev = 0;
  printf("  %s: ", label);
  while (fp > lo && fp < hi && fp > prev && depth < 12) {
    uword* f = reinterpret_cast<uword*>(fp);
    uword ret = f[1];
    if (ret == 0) break;
    printf("%s0x%llx", depth ? " <- " : "", (unsigned long long)ret);
    prev = fp;
    fp = f[0];
    depth++;
  }
  printf("\n  %s: walked %d frame(s)\n", label, depth);
  return depth;
}

__declspec(noinline) void Depth3(uword lo, uword hi) {
  printf("\n[2] walking from a 3-deep call chain\n");
  WalkFrom(FpViaIntrinsic(), lo, hi, "intrinsic");
  WalkFrom(FpViaContext(), lo, hi, "context  ");
  // What the VM does TODAY, for contrast: hand the walker the stack pointer.
  uword sp = reinterpret_cast<uword>(_AddressOfReturnAddress());
  WalkFrom(sp + 4096, lo, hi, "sp(today)");
}
__declspec(noinline) void Depth2(uword lo, uword hi) { Depth3(lo, hi); }
__declspec(noinline) void Depth1(uword lo, uword hi) { Depth2(lo, hi); }

// --- 3. what does each cost? -------------------------------------------------
volatile uword g_sink;

__declspec(noinline) void Cost() {
  const int N = 2000000;
  LARGE_INTEGER freq, a, b, c;
  QueryPerformanceFrequency(&freq);

  QueryPerformanceCounter(&a);
  for (int i = 0; i < N; i++) g_sink = FpViaIntrinsic();
  QueryPerformanceCounter(&b);
  for (int i = 0; i < N; i++) g_sink = FpViaContext();
  QueryPerformanceCounter(&c);

  double ns_i = (double)(b.QuadPart - a.QuadPart) * 1e9 / freq.QuadPart / N;
  double ns_c = (double)(c.QuadPart - b.QuadPart) * 1e9 / freq.QuadPart / N;
  printf("\n[3] cost per call (%d iterations)\n", N);
  printf("  intrinsic : %7.2f ns\n", ns_i);
  printf("  context   : %7.2f ns   (%.0fx)\n", ns_c, ns_c / ns_i);
}

int main() {
  ULONG_PTR lo = 0, hi = 0;
  GetCurrentThreadStackLimits(&lo, &hi);
  printf("stack bounds: 0x%llx .. 0x%llx\n\n", (unsigned long long)lo,
         (unsigned long long)hi);

  printf("[1] do the two agree in one frame?\n");
  Agreement();

  Depth1((uword)lo, (uword)hi);
  Cost();
  return 0;
}
