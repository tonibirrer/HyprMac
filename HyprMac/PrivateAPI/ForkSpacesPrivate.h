// fork: read-only Space queries for native-fullscreen workspace members
// (FullscreenSpaces.swift). Upstream dropped its Space SPI header in v0.21.0;
// these three calls only read window server state and work with SIP enabled.

#ifndef ForkSpacesPrivate_h
#define ForkSpacesPrivate_h

#include <CoreGraphics/CoreGraphics.h>

typedef int CGSConnectionID;
typedef uint64_t CGSSpaceID;
typedef int CGSSpaceType;

// connection to the window server
extern CGSConnectionID _CGSDefaultConnection(void);

// all spaces, organized by display
extern CFArrayRef _Nullable CGSCopyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;

// the space ID(s) a window is on
extern CFArrayRef _Nullable CGSCopySpacesForWindows(CGSConnectionID cid, CGSSpaceType type, CFArrayRef _Nonnull windowIDs) CF_RETURNS_RETAINED;

#endif
