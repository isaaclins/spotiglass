// The HAL driver's read-and-filter step, callable from the Swift tests. The driver's own
// frame type holds an atomic counter Swift can't import, so the tests reach the driver
// through this function instead of through its structs.

#ifndef SPOTIGLASS_EQ_DRIVER_TEST_SHIM_H
#define SPOTIGLASS_EQ_DRIVER_TEST_SHIM_H

#include <stddef.h>

/// Does what the plugin's IO callback does with one buffer: opens the driver's reader on
/// `backingPath` (the file the app's `EQCoefficientPublisher` wrote), takes a snapshot of the
/// published frame and filters the interleaved stereo `buffer` in place with `EQDSP_Apply`,
/// starting from fresh filter state. Returns the snapshot status (0 when the frame was read),
/// or -1 when the reader could not open the file.
int EQDriverTest_RenderPublishedFrame(const char* backingPath, float* buffer, size_t frameCount);

#endif
