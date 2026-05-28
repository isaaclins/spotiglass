// SpotiglassEQDriver / EQCoefficientReader.c

#include "EQCoefficientReader.h"

#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct EQCoefficientReader {
    int fd;
    void* mapping;
    size_t mappingSize;
    /// Pointer into the mmap region. Marked _Atomic so the loads are
    /// guaranteed-ordered without barriers in the hot path.
    EQCoefficientFrame* frame;
};

EQCoefficientReader* EQCoefficientReader_Open(const char* backingPath) {
    if (!backingPath) return NULL;
    int fd = open(backingPath, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat sb;
    if (fstat(fd, &sb) != 0) {
        close(fd);
        return NULL;
    }
    // Use the wire-format size (220), not sizeof(EQCoefficientFrame) which is
    // 224 (4 bytes of trailing C alignment padding). The Swift publisher
    // writes exactly the wire layout.
    if ((size_t)sb.st_size < SPOTIGLASS_EQ_WIRE_BYTES) {
        close(fd);
        return NULL;
    }
    void* mapping = mmap(NULL, (size_t)sb.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    EQCoefficientReader* reader = (EQCoefficientReader*)calloc(1, sizeof(EQCoefficientReader));
    if (!reader) {
        munmap(mapping, (size_t)sb.st_size);
        close(fd);
        return NULL;
    }
    reader->fd = fd;
    reader->mapping = mapping;
    reader->mappingSize = (size_t)sb.st_size;
    reader->frame = (EQCoefficientFrame*)mapping;
    return reader;
}

void EQCoefficientReader_Close(EQCoefficientReader* reader) {
    if (!reader) return;
    if (reader->mapping && reader->mapping != MAP_FAILED) {
        munmap(reader->mapping, reader->mappingSize);
    }
    if (reader->fd >= 0) close(reader->fd);
    free(reader);
}

int EQCoefficientReader_Snapshot(EQCoefficientReader* reader, EQCoefficientFrame* out) {
    if (!reader || !reader->frame || !out) return 2;

    // Seqlock read: load sequence, check even, copy payload, reload sequence.
    uint64_t s1 = atomic_load_explicit(&reader->frame->sequence, memory_order_acquire);
    if (s1 & 1ULL) {
        // Writer mid-update. Caller falls back to its cached frame.
        return 1;
    }

    EQCoefficientFrame tmp;
    // Copy everything EXCEPT the sequence (we already have s1 in flight).
    tmp.preampLinear = reader->frame->preampLinear;
    memcpy(tmp.bandCoeffs, reader->frame->bandCoeffs, sizeof(tmp.bandCoeffs));
    tmp.sampleRateHz = reader->frame->sampleRateHz;
    tmp.enabledMask = reader->frame->enabledMask;

    uint64_t s2 = atomic_load_explicit(&reader->frame->sequence, memory_order_acquire);
    if (s2 != s1) {
        // Writer raced us mid-copy; payload may be torn.
        return 1;
    }

    // Stable read.
    atomic_store_explicit(&out->sequence, s1, memory_order_relaxed);
    out->preampLinear = tmp.preampLinear;
    memcpy(out->bandCoeffs, tmp.bandCoeffs, sizeof(out->bandCoeffs));
    out->sampleRateHz = tmp.sampleRateHz;
    out->enabledMask = tmp.enabledMask;
    return 0;
}
