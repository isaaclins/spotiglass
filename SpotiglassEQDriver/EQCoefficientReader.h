// SpotiglassEQDriver / EQCoefficientReader.h
//
// Real-time-safe reader for the GUI -> HAL coefficient channel.
//
// Lifecycle (NON-realtime, called from the device's StartIO/StopIO):
//   - EQCoefficientReader_Open  : opens & mmap()s the backing file
//   - EQCoefficientReader_Close : munmap()s and clears state
//
// Per-IO-cycle (REALTIME, called from DoIOOperation):
//   - EQCoefficientReader_Snapshot
//       Returns 1 if a torn read was detected (caller should use the
//       previously-cached frame on this cycle and retry next time).
//       Returns 0 on success and fills *out with the freshly-loaded frame.
//
// The reader makes NO syscalls in the hot path (mmap is set up once, and
// the per-cycle access is just two atomic loads + a memcpy of ~228 bytes).

#ifndef SPOTIGLASS_EQ_COEFFICIENT_READER_H
#define SPOTIGLASS_EQ_COEFFICIENT_READER_H

#include "EQCoefficientFrame.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EQCoefficientReader EQCoefficientReader;

/// Opens the shared-memory channel. `backingPath` must match the path the
/// GUI publisher writes to (uid-suffixed; see EQCoefficientPublisher.swift).
/// Returns NULL on any failure (file missing, mmap failed, etc.); the plugin
/// then falls back to a passthrough (no filtering) until the next StartIO.
EQCoefficientReader* EQCoefficientReader_Open(const char* backingPath);

void EQCoefficientReader_Close(EQCoefficientReader* reader);

/// Real-time-safe snapshot. Returns:
///   0 -> success, `out` filled
///   1 -> torn read detected, `out` unchanged; caller uses cached frame
///   2 -> reader is NULL or mapping is invalid
/// NEVER allocates, NEVER takes locks, NEVER calls into syscalls.
int EQCoefficientReader_Snapshot(EQCoefficientReader* reader, EQCoefficientFrame* out);

#ifdef __cplusplus
}
#endif

#endif // SPOTIGLASS_EQ_COEFFICIENT_READER_H
