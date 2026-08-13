// fp_probe2.cpp - WINDARTARM AS7, follow-up to fp_probe.cpp.
//
// fp_probe said: _AddressOfReturnAddress()-8 and RtlCaptureContext().Fp
// disagree by 56 bytes, and walking [x29] -> {caller_fp, lr} from EITHER of
// them yields nonsense. The hypothesis that follows is uncomfortable but
// likely: Windows/arm64 MSVC does not maintain the frame-pointer CHAIN the
// Dart profiler's walker assumes ([fp+0]=caller fp, [fp+8]=return address).
// Windows unwinds from .pdata/.xdata, not from a chain, so the compiler is
// free to place the saved pair wherever it likes - or omit it.
//
// If that is true, NO value of COPY_FP_REGISTER fixes native crash stacks and
// the fix has to be the OS unwinder. This probe settles it:
//
//   1. Dump the words around x29 and find where the return address actually is.
//   2. RtlCaptureStackBackTrace - does the OS walk our chain correctly?
//   3. A manual RtlVirtualUnwind loop - frames, and the Fp each one reports.
//
//   cl /O2 /EHsc fp_probe2.cpp /link dbghelp.lib
#include <windows.h>
#include <intrin.h>
#include <stdio.h>
#include <stdint.h>

typedef uintptr_t uword;

// Known landmarks, so we can tell a real return address from a plausible one.
__declspec(noinline) void Inner();
__declspec(noinline) void Middle();
__declspec(noinline) void Outer();

static uword g_inner, g_middle, g_outer;

static const char* Landmark(uword pc) {
  struct { uword base; const char* name; } marks[] = {
      {g_inner, "Inner"}, {g_middle, "Middle"}, {g_outer, "Outer"}};
  const char* best = NULL;
  uword bestd = 4096;
  for (int i = 0; i < 3; i++) {
    if (pc >= marks[i].base && pc - marks[i].base < bestd) {
      bestd = pc - marks[i].base;
      best = marks[i].name;
    }
  }
  return best ? best : "?";
}

// --- 1. where is the return address, really? --------------------------------
static void DumpAroundFp() {
  CONTEXT ctx;
  RtlCaptureContext(&ctx);
  uword fp = (uword)ctx.Fp;
  uword lr = (uword)ctx.Lr;
  printf("  x29 = 0x%llx   x30(lr) = 0x%llx -> %s\n", (unsigned long long)fp,
         (unsigned long long)lr, Landmark(lr));
  printf("  words around x29 (looking for lr):\n");
  for (int off = -8; off <= 8; off++) {
    uword* p = reinterpret_cast<uword*>(fp) + off;
    uword v = *p;
    const char* tag = "";
    if (v == lr) tag = "  <== the return address lives HERE";
    printf("    [x29 %+3d*8] = 0x%016llx%s\n", off, (unsigned long long)v, tag);
  }
}

// --- 2 & 3. the OS unwinder --------------------------------------------------
static void CaptureBackTrace() {
  void* frames[24];
  USHORT n = RtlCaptureStackBackTrace(0, 24, frames, NULL);
  printf("  RtlCaptureStackBackTrace: %u frame(s)\n", n);
  for (USHORT i = 0; i < n && i < 8; i++) {
    uword pc = (uword)frames[i];
    printf("    #%u 0x%llx  %s\n", i, (unsigned long long)pc, Landmark(pc));
  }
}

static void VirtualUnwindLoop() {
  CONTEXT ctx;
  RtlCaptureContext(&ctx);
  printf("  RtlVirtualUnwind loop:\n");
  for (int depth = 0; depth < 8; depth++) {
    uword pc = (uword)ctx.Pc;
    if (pc == 0) break;
    printf("    #%d pc=0x%llx fp=0x%llx sp=0x%llx  %s\n", depth,
           (unsigned long long)pc, (unsigned long long)ctx.Fp,
           (unsigned long long)ctx.Sp, Landmark(pc));
    DWORD64 imageBase = 0;
    PRUNTIME_FUNCTION rf = RtlLookupFunctionEntry(pc, &imageBase, NULL);
    if (rf == NULL) {
      printf("    (no unwind info for this pc - stopping)\n");
      break;
    }
    PVOID handlerData = NULL;
    DWORD64 establisherFrame = 0;
    RtlVirtualUnwind(UNW_FLAG_NHANDLER, imageBase, pc, rf, &ctx, &handlerData,
                     &establisherFrame, NULL);
  }
}

__declspec(noinline) void Inner() {
  printf("\n[1] where does MSVC/arm64 actually put the return address?\n");
  DumpAroundFp();
  printf("\n[2] does the OS unwinder walk it?\n");
  CaptureBackTrace();
  printf("\n[3] manual unwind, with the Fp each frame reports\n");
  VirtualUnwindLoop();
}
__declspec(noinline) void Middle() { Inner(); }
__declspec(noinline) void Outer() { Middle(); }

int main() {
  g_inner = (uword)&Inner;
  g_middle = (uword)&Middle;
  g_outer = (uword)&Outer;
  printf("landmarks: Inner=0x%llx Middle=0x%llx Outer=0x%llx\n",
         (unsigned long long)g_inner, (unsigned long long)g_middle,
         (unsigned long long)g_outer);
  Outer();
  return 0;
}
