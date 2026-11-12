#include "EQDriverTestShim.h"

#include "../../SpotiglassEQDriver/EQCoefficientReader.h"
#include "../../SpotiglassEQDriver/SpotiglassEQDSP.h"

int EQDriverTest_RenderPublishedFrame(const char* backingPath, float* buffer, size_t frameCount) {
    EQCoefficientReader* reader = EQCoefficientReader_Open(backingPath);
    if (!reader) return -1;
    EQCoefficientFrame frame;
    const int status = EQCoefficientReader_Snapshot(reader, &frame);
    EQCoefficientReader_Close(reader);
    if (status != 0) return status;
    EQDSPState state;
    EQDSP_Reset(&state);
    EQDSP_Apply(&state, &frame, buffer, frameCount);
    return 0;
}
