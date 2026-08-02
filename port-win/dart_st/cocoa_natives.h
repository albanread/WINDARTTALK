// windart dart:cocoa native resolver — declarations.
//
// Mirrors dart_win32/win_natives.h (WinNativeLookup/WinNativeSymbol) so the
// embedder's builtin_natives.cc can fall through to the Smalltalk (dart:cocoa)
// natives after dart:io and dart:win.
#ifndef WINDART_DART_ST_COCOA_NATIVES_H_
#define WINDART_DART_ST_COCOA_NATIVES_H_

#include "include/dart_api.h"

namespace dart {
namespace bin {

Dart_NativeFunction CocoaNativeLookup(Dart_Handle name,
                                      int argument_count,
                                      bool* auto_setup_scope);
const uint8_t* CocoaNativeSymbol(Dart_NativeFunction nf);

}  // namespace bin
}  // namespace dart

#endif  // WINDART_DART_ST_COCOA_NATIVES_H_
