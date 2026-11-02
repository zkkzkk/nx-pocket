// The Mach-O image this code is linked into: the Mac host, the iOS app, or a game pack's library (NX Pocket loads one with dlopen, dm/ios/pocket). getsectiondata on it finds
// this image's own sections (the HLE tables, the embedded modules) wherever dyld put it; _mh_execute_header is the main executable's, which holds none of them when the host is a library
#pragma once
#include <mach-o/loader.h>
extern const struct mach_header_64 __dso_handle;   // the linker defines it in every image, at that image's header
#define DM_IMAGE (&__dso_handle)
