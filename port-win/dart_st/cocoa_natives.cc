// windart dart:cocoa native resolver.
//
// The name+argc -> Dart_NativeFunction table for the "dart:cocoa" library
// (cocoa.dart's `native "ST_..."` declarations). Mirrors
// dart_win32/win_natives.cpp (WinNativeLookup), which itself mirrors MACDART's
// cocoa/cocoa_natives.mm CocoaNativeLookup (:824) — but here we resolve ONLY
// the portable Smalltalk runtime natives (the 42 ST_* defined in st_natives.cc).
//
// The macOS Cocoa/objc, game-pane, workspace and SQLite natives that cocoa.dart
// also declares are intentionally ABSENT: windart is headless-ST with the
// dart:win GUI, so a dropped native simply resolves to NULL and throws only if
// it is ever actually called — which never happens on the core ST run path.
//
// Registered in the embedder exactly like WinNativeLookup: builtin_natives.cc
// falls through to CocoaNativeLookup, and dart:cocoa is registered in
// builtin.cc / dartutils.cc (see the dart:cocoa hunks in windart-port.patch).

#include <stdio.h>
#include <string.h>

#include "include/dart_api.h"
#include "win_natives.h"   // WINDARTARM: Cocoa_gp* -> Win_gp* delegation

namespace dart {
namespace bin {

// Portable ST runtime natives — DEFINED in st_natives.cc.
void ST_load(Dart_NativeArguments args);
void ST_invokeStatic(Dart_NativeArguments args);
void ST_new(Dart_NativeArguments args);
void ST_send(Dart_NativeArguments args);
void ST_classSend(Dart_NativeArguments args);
void ST_basicNewFromType(Dart_NativeArguments args);
void ST_run(Dart_NativeArguments args);
void ST_classSendTry(Dart_NativeArguments args);
void ST_extSendTry(Dart_NativeArguments args);
void ST_classOf(Dart_NativeArguments args);
void ST_loadFresh(Dart_NativeArguments args);
void ST_outline(Dart_NativeArguments args);
void ST_sendTry(Dart_NativeArguments args);
void ST_getField(Dart_NativeArguments args);
void ST_hasMethod(Dart_NativeArguments args);
void ST_respondsTo(Dart_NativeArguments args);
void ST_blockNumArgs(Dart_NativeArguments args);
void ST_classNamed(Dart_NativeArguments args);
void ST_asSymbol(Dart_NativeArguments args);
void ST_ffiCall(Dart_NativeArguments args);
void ST_peekByte(Dart_NativeArguments args);
void ST_pokeByte(Dart_NativeArguments args);
void ST_peekF64(Dart_NativeArguments args);
void ST_pokeF64(Dart_NativeArguments args);
void ST_peekI64(Dart_NativeArguments args);
void ST_pokeI64(Dart_NativeArguments args);
void ST_classNameOf(Dart_NativeArguments args);
void ST_superclassOf(Dart_NativeArguments args);
void ST_allClasses(Dart_NativeArguments args);
void ST_selectorsOf(Dart_NativeArguments args);
void ST_instVarNamesOf(Dart_NativeArguments args);
void ST_classVarNamesOf(Dart_NativeArguments args);
void ST_gcScavenge(Dart_NativeArguments args);
void ST_gcFull(Dart_NativeArguments args);
void ST_gcStats(Dart_NativeArguments args);
void ST_isKindOf(Dart_NativeArguments args);
void ST_check(Dart_NativeArguments args);
void ST_becomeForward(Dart_NativeArguments args);
void ST_become(Dart_NativeArguments args);
void ST_shallowCopy(Dart_NativeArguments args);
void ST_instVarAt(Dart_NativeArguments args);
void ST_instVarAtPut(Dart_NativeArguments args);
void ST_eq(Dart_NativeArguments args);          // cached `=` dispatch (perf arc)
void ST_symbolFor(Dart_NativeArguments args);   // interned symbol lookup (perf arc)

#define COCOA_NATIVE_LIST(V)                                                   \
  V(ST_load, 1)                                                                \
  V(ST_invokeStatic, 3)                                                        \
  V(ST_new, 1)                                                                 \
  V(ST_send, 3)                                                                \
  V(ST_classSend, 3)                                                           \
  V(ST_basicNewFromType, 1)                                                    \
  V(ST_run, 1)                                                                 \
  V(ST_classSendTry, 3)                                                        \
  V(ST_extSendTry, 3)                                                          \
  V(ST_classOf, 1)                                                             \
  V(ST_loadFresh, 1)                                                           \
  V(ST_outline, 1)                                                             \
  V(ST_sendTry, 3)                                                             \
  V(ST_getField, 2)                                                            \
  V(ST_hasMethod, 2)                                                           \
  V(ST_respondsTo, 2)                                                          \
  V(ST_blockNumArgs, 1)                                                        \
  V(ST_classNamed, 1)                                                          \
  V(ST_asSymbol, 1)                                                            \
  V(ST_ffiCall, 2)                                                             \
  V(ST_peekByte, 1)                                                            \
  V(ST_pokeByte, 2)                                                            \
  V(ST_peekF64, 1)                                                             \
  V(ST_pokeF64, 2)                                                             \
  V(ST_peekI64, 1)                                                             \
  V(ST_pokeI64, 2)                                                             \
  V(ST_classNameOf, 1)                                                         \
  V(ST_superclassOf, 1)                                                        \
  V(ST_allClasses, 0)                                                          \
  V(ST_selectorsOf, 1)                                                         \
  V(ST_instVarNamesOf, 1)                                                      \
  V(ST_classVarNamesOf, 1)                                                     \
  V(ST_gcScavenge, 0)                                                          \
  V(ST_gcFull, 0)                                                              \
  V(ST_gcStats, 0)                                                             \
  V(ST_isKindOf, 2)                                                            \
  V(ST_check, 1)                                                               \
  V(ST_becomeForward, 2)                                                       \
  V(ST_become, 2)                                                              \
  V(ST_shallowCopy, 1)                                                         \
  V(ST_instVarAt, 2)                                                           \
  V(ST_instVarAtPut, 3)                                                        \
  V(ST_eq, 2)                                                                  \
  V(ST_symbolFor, 1)

static struct CocoaEntry {
  const char* name_;
  Dart_NativeFunction function_;
  int argument_count_;
} CocoaEntries[] = {
#define COCOA_ENTRY(name, argc) {#name, name, argc},
    COCOA_NATIVE_LIST(COCOA_ENTRY)
#undef COCOA_ENTRY
};

Dart_NativeFunction CocoaNativeLookup(Dart_Handle name,
                                      int argument_count,
                                      bool* auto_setup_scope) {
  const char* function_name = NULL;
  if (Dart_IsError(Dart_StringToCString(name, &function_name))) return NULL;
  if (auto_setup_scope != NULL) *auto_setup_scope = true;
  int num_entries = sizeof(CocoaEntries) / sizeof(struct CocoaEntry);
  for (int i = 0; i < num_entries; i++) {
    struct CocoaEntry* entry = &CocoaEntries[i];
    if (strcmp(function_name, entry->name_) == 0 &&
        entry->argument_count_ == argument_count) {
      return entry->function_;
    }
  }
  // WINDARTARM: the gamepane natives dart:cocoa declares are named Cocoa_gp*
  // (cocoa.dart is shared with MACDART, where Cocoa_ IS the platform prefix).
  // Windows implements the identical contract as Win_gp* in
  // dart_win32/gp_natives_win.cpp — Open/Close/Apply/Snap/Stat/Backbuffer/
  // Fullscreen, matching arities. Rewrite the prefix and let the dart:win
  // resolver answer, rather than duplicating a table that would then need
  // maintaining twice. Delegating also keeps the arity check (WinNativeLookup
  // matches on name AND argument_count), so a mismatch still fails closed.
  //
  // Without this the ST gamepane path resolved to nothing and the embedder fell
  // through to Builtin_DummyNative -> UNREACHABLE() (builtin_natives.cc:45),
  // killing the VM the moment a Smalltalk game called into the pane.
  if (strncmp(function_name, "Cocoa_gp", 8) == 0) {
    char win_name[64];
    snprintf(win_name, sizeof(win_name), "Win_gp%s", function_name + 8);
    return WinNativeLookup(Dart_NewStringFromCString(win_name), argument_count,
                           auto_setup_scope);
  }
  return NULL;
}

const uint8_t* CocoaNativeSymbol(Dart_NativeFunction nf) {
  int num_entries = sizeof(CocoaEntries) / sizeof(struct CocoaEntry);
  for (int i = 0; i < num_entries; i++) {
    if (CocoaEntries[i].function_ == nf) {
      return reinterpret_cast<const uint8_t*>(CocoaEntries[i].name_);
    }
  }
  return NULL;
}

}  // namespace bin
}  // namespace dart
