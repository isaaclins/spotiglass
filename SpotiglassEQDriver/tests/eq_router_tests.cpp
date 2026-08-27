// Unit tests for the parts of the router that are reachable without audio
// hardware: output-layout classification, frame writing, and the router
// lifetime used to retire a router while a render callback may be reading it.
//
// The driver is built by build-driver.sh rather than Xcode, so it has no test
// target. run-driver-tests.sh compiles this against EQRouter.cpp and runs it.
// EQRouter_OpenWithError is never called, so nothing here touches CoreAudio devices.

#include "../EQRouter.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <vector>

namespace {

int gFailures = 0;

void expect(bool condition, const char* what) {
    if (condition) return;
    std::fprintf(stderr, "FAIL: %s\n", what);
    gFailures += 1;
}

void expectEqual(float actual, float expected, const char* what) {
    if (actual == expected) return;
    std::fprintf(stderr, "FAIL: %s (got %f, expected %f)\n", what, actual, expected);
    gFailures += 1;
}

// MARK: - Layout classification

void testClassifyInterleavedStereo() {
    float storage[8] = {0};
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 2;
    list.mBuffers[0].mDataByteSize = sizeof(storage);
    list.mBuffers[0].mData = storage;

    expect(EQRouter_ClassifyOutputLayout(&list) == EQRouterOutputLayoutInterleavedStereo,
           "one two-channel buffer is interleaved stereo");
}

void testClassifyNonInterleavedStereo() {
    float left[4] = {0};
    float right[4] = {0};
    std::vector<unsigned char> backing(sizeof(AudioBufferList) + sizeof(AudioBuffer));
    auto* list = reinterpret_cast<AudioBufferList*>(backing.data());
    list->mNumberBuffers = 2;
    list->mBuffers[0].mNumberChannels = 1;
    list->mBuffers[0].mDataByteSize = sizeof(left);
    list->mBuffers[0].mData = left;
    list->mBuffers[1].mNumberChannels = 1;
    list->mBuffers[1].mDataByteSize = sizeof(right);
    list->mBuffers[1].mData = right;

    expect(EQRouter_ClassifyOutputLayout(list) == EQRouterOutputLayoutNonInterleavedStereo,
           "two one-channel buffers are non-interleaved stereo");
}

void testClassifyRejectsUnsupported() {
    expect(EQRouter_ClassifyOutputLayout(nullptr) == EQRouterOutputLayoutUnsupported,
           "null buffer list is unsupported");

    float storage[8] = {0};
    AudioBufferList mono{};
    mono.mNumberBuffers = 1;
    mono.mBuffers[0].mNumberChannels = 1;
    mono.mBuffers[0].mDataByteSize = sizeof(storage);
    mono.mBuffers[0].mData = storage;
    expect(EQRouter_ClassifyOutputLayout(&mono) == EQRouterOutputLayoutUnsupported,
           "a single mono buffer is unsupported");

    AudioBufferList sixChannel{};
    sixChannel.mNumberBuffers = 1;
    sixChannel.mBuffers[0].mNumberChannels = 6;
    sixChannel.mBuffers[0].mDataByteSize = sizeof(storage);
    sixChannel.mBuffers[0].mData = storage;
    expect(EQRouter_ClassifyOutputLayout(&sixChannel) == EQRouterOutputLayoutUnsupported,
           "5.1 is unsupported");
}

// MARK: - Frame writing
//
// This is the #254 regression: non-interleaved output was written as if it
// were interleaved, so the right channel received the left channel's odd
// samples and stereo collapsed.

void testWriteInterleavedPreservesOrder() {
    const float frames[6] = {1, -1, 2, -2, 3, -3};
    float storage[6] = {0};
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 2;
    list.mBuffers[0].mDataByteSize = sizeof(storage);
    list.mBuffers[0].mData = storage;

    expect(EQRouter_WriteFrames(frames, 3, &list, 0) == 0, "interleaved write succeeds");
    for (int i = 0; i < 6; ++i) {
        expectEqual(storage[i], frames[i], "interleaved sample round-trips");
    }
}

void testWriteNonInterleavedSplitsChannels() {
    const float frames[6] = {1, -1, 2, -2, 3, -3};
    float left[3] = {0};
    float right[3] = {0};
    std::vector<unsigned char> backing(sizeof(AudioBufferList) + sizeof(AudioBuffer));
    auto* list = reinterpret_cast<AudioBufferList*>(backing.data());
    list->mNumberBuffers = 2;
    list->mBuffers[0].mNumberChannels = 1;
    list->mBuffers[0].mDataByteSize = sizeof(left);
    list->mBuffers[0].mData = left;
    list->mBuffers[1].mNumberChannels = 1;
    list->mBuffers[1].mDataByteSize = sizeof(right);
    list->mBuffers[1].mData = right;

    expect(EQRouter_WriteFrames(frames, 3, list, 0) == 0, "non-interleaved write succeeds");
    expectEqual(left[0], 1, "left frame 0");
    expectEqual(left[1], 2, "left frame 1");
    expectEqual(left[2], 3, "left frame 2");
    expectEqual(right[0], -1, "right frame 0");
    expectEqual(right[1], -2, "right frame 1");
    expectEqual(right[2], -3, "right frame 2");
}

void testWriteHonoursFrameOffset() {
    const float frames[2] = {7, -7};
    float left[3] = {0, 0, 0};
    float right[3] = {0, 0, 0};
    std::vector<unsigned char> backing(sizeof(AudioBufferList) + sizeof(AudioBuffer));
    auto* list = reinterpret_cast<AudioBufferList*>(backing.data());
    list->mNumberBuffers = 2;
    list->mBuffers[0].mNumberChannels = 1;
    list->mBuffers[0].mDataByteSize = sizeof(left);
    list->mBuffers[0].mData = left;
    list->mBuffers[1].mNumberChannels = 1;
    list->mBuffers[1].mDataByteSize = sizeof(right);
    list->mBuffers[1].mData = right;

    expect(EQRouter_WriteFrames(frames, 1, list, 2) == 0, "offset write succeeds");
    expectEqual(left[0], 0, "offset leaves earlier left frames untouched");
    expectEqual(left[2], 7, "offset writes the requested left frame");
    expectEqual(right[2], -7, "offset writes the requested right frame");
}

void testWriteRejectsOverrun() {
    const float frames[6] = {1, -1, 2, -2, 3, -3};
    float storage[2] = {0};
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 2;
    list.mBuffers[0].mDataByteSize = sizeof(storage);
    list.mBuffers[0].mData = storage;

    expect(EQRouter_WriteFrames(frames, 3, &list, 0) != 0,
           "a write past the end of the buffer is refused");
    expect(EQRouter_WriteFrames(nullptr, 3, &list, 0) != 0, "null source is refused");
    expect(EQRouter_WriteFrames(frames, 0, &list, 0) != 0, "zero frames is refused");
}

// MARK: - Router lifetime
//
// This is the #248 regression: a router could be closed while a render
// callback still held it. A lease must keep a retired router alive until the
// reader is done, and the waiter must never observe zero while a reader holds
// a lease.

struct LeaseHammerContext {
    EQRouterLifetime* lifetime;
    std::atomic<bool> stop;
    std::atomic<uint64_t> observedNull;
    std::atomic<uint64_t> iterations;
};

void* leaseHammer(void* raw) {
    auto* context = static_cast<LeaseHammerContext*>(raw);
    while (!context->stop.load(std::memory_order_seq_cst)) {
        EQRouter* leased = context->lifetime->acquire();
        if (leased == nullptr) {
            context->observedNull.fetch_add(1, std::memory_order_seq_cst);
        } else {
            context->lifetime->release();
        }
        context->iterations.fetch_add(1, std::memory_order_seq_cst);
    }
    return nullptr;
}

void testLifetimePublishesAndRetires() {
    auto* first = reinterpret_cast<EQRouter*>(0x1);
    auto* second = reinterpret_cast<EQRouter*>(0x2);
    EQRouterLifetime lifetime(first);

    expect(lifetime.hasRouter(), "starts with a router");
    EQRouter* leased = lifetime.acquire();
    expect(leased == first, "lease sees the published router");

    EQRouter* retired = lifetime.swap(second);
    expect(retired == first, "swap returns the retired router");
    expect(lifetime.acquire() == second, "a new lease sees the replacement");
    lifetime.release();
    lifetime.release();

    lifetime.waitForUsers();
    expect(true, "waitForUsers returns once every lease is released");
}

void testLifetimeAcquireOnEmptyDoesNotLeakALease() {
    EQRouterLifetime lifetime(nullptr);
    expect(lifetime.acquire() == nullptr, "acquiring an empty lifetime yields null");
    // If the null path leaked a lease, this would spin forever.
    lifetime.waitForUsers();
    expect(true, "an empty acquire released its own lease");
}

void testLifetimeRetirementWaitsForConcurrentReaders() {
    auto* first = reinterpret_cast<EQRouter*>(0x1);
    auto* second = reinterpret_cast<EQRouter*>(0x2);
    EQRouterLifetime lifetime(first);

    LeaseHammerContext context{&lifetime, {false}, {0}, {0}};
    pthread_t reader{};
    expect(pthread_create(&reader, nullptr, leaseHammer, &context) == 0, "reader thread starts");

    while (context.iterations.load(std::memory_order_seq_cst) < 1000) {
    }

    EQRouter* retired = lifetime.swap(second);
    lifetime.waitForUsers();
    expect(retired == first, "retired the previously published router");

    context.stop.store(true, std::memory_order_seq_cst);
    pthread_join(reader, nullptr);

    expect(context.observedNull.load(std::memory_order_seq_cst) == 0,
           "a reader never observes a torn or null router across a swap");
}

}  // namespace

int main() {
    testClassifyInterleavedStereo();
    testClassifyNonInterleavedStereo();
    testClassifyRejectsUnsupported();

    testWriteInterleavedPreservesOrder();
    testWriteNonInterleavedSplitsChannels();
    testWriteHonoursFrameOffset();
    testWriteRejectsOverrun();

    testLifetimePublishesAndRetires();
    testLifetimeAcquireOnEmptyDoesNotLeakALease();
    testLifetimeRetirementWaitsForConcurrentReaders();

    if (gFailures == 0) {
        std::printf("driver router tests: all checks passed\n");
        return 0;
    }
    std::fprintf(stderr, "driver router tests: %d check(s) failed\n", gFailures);
    return 1;
}
