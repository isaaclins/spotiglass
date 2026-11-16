// Unit tests for the parts of the router that are reachable without audio
// hardware: output-layout classification, frame writing, and the router
// lifetime used to retire a router while a render callback may be reading it.
//
// The driver is built by build-driver.sh rather than Xcode, so it has no test
// target. run-driver-tests.sh compiles this against EQRouter.cpp and runs it.
// EQRouter_OpenWithError is never called, so nothing here touches CoreAudio devices.

#include "../EQClock.h"
#include "../EQRouter.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <cmath>
#include <cstdlib>
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


// MARK: - Two clocks (#590)

// What the target device heard: frames are numbered (stored as two floats so
// the number survives exactly), silence is (0, 0).
struct Playback {
    uint64_t silentAfterStart = 0;  // silent frames once sound had started
    uint64_t skipped = 0;           // single frames left out
    uint64_t repeated = 0;          // single frames played twice
    uint64_t cuts = 0;              // places where more than one frame went missing
    uint64_t longestCut = 0;
    uint64_t frames = 0;
    uint64_t slipsAfterWarmUp = 0;  // skips and repeats after the first 30 s
};

void encode(uint64_t number, float* out) {
    out[0] = static_cast<float>(number % 4096);
    out[1] = static_cast<float>(number / 4096);
}

// The EQ device pushes `producerChunk` frames at `producerRate`, the target
// pulls `consumerChunk` frames at `consumerRate`, for `seconds`. Each side runs
// on its own clock, like the Mac's host clock and the speakers' crystal.
Playback playTwoClocks(double producerRate, size_t producerChunk,
                       double consumerRate, size_t consumerChunk,
                       double seconds) {
    auto* ring = new EQRouterRing();
    EQRouterRing_Reset(ring);
    Playback result;
    std::vector<float> in(producerChunk * 2);
    std::vector<float> out(consumerChunk * 2);
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 2;
    list.mBuffers[0].mDataByteSize = static_cast<UInt32>(out.size() * sizeof(float));
    list.mBuffers[0].mData = out.data();

    uint64_t produced = 0;
    uint64_t pushes = 0;
    uint64_t pulls = 0;
    bool started = false;
    uint64_t last = 0;
    while (true) {
        const double nextPush = static_cast<double>(pushes) * producerChunk / producerRate;
        const double nextPull = static_cast<double>(pulls) * consumerChunk / consumerRate;
        if (nextPush > seconds && nextPull > seconds) break;
        if (nextPush <= nextPull) {
            for (size_t i = 0; i < producerChunk; ++i) encode(++produced, &in[i * 2]);
            EQRouterRing_Push(ring, in.data(), producerChunk);
            pushes += 1;
            continue;
        }
        expect(EQRouterRing_Pull(ring, &list) == 0, "the ring fills an output cycle");
        pulls += 1;
        for (size_t i = 0; i < consumerChunk; ++i) {
            const float* frame = &out[i * 2];
            if (frame[0] == 0.0f && frame[1] == 0.0f) {
                if (started) result.silentAfterStart += 1;
                continue;
            }
            const uint64_t number = static_cast<uint64_t>(frame[1]) * 4096 + static_cast<uint64_t>(frame[0]);
            if (started) {
                if (number == last) {
                    result.repeated += 1;
                    if (nextPull > 30.0) result.slipsAfterWarmUp += 1;
                } else if (number == last + 2) {
                    result.skipped += 1;
                    if (nextPull > 30.0) result.slipsAfterWarmUp += 1;
                } else if (number != last + 1) {
                    result.cuts += 1;
                    const uint64_t gap = number > last ? number - last - 1 : last - number + 1;
                    if (gap > result.longestCut) result.longestCut = gap;
                }
            }
            started = true;
            last = number;
            result.frames += 1;
        }
    }
    delete ring;
    return result;
}

void testSameRateWithClockDriftPlaysWithoutCuts() {
    // Ten minutes, the speakers' crystal 80 ppm slow and then 80 ppm fast
    // against the host clock: before #590 the ring overflowed (or ran dry)
    // every few minutes and dropped a whole IO buffer (or played silence).
    for (const double drift : {-80e-6, 80e-6}) {
        const Playback heard = playTwoClocks(48000.0, 512, 48000.0 * (1.0 + drift), 512, 600.0);
        expect(heard.cuts == 0, "clock drift never cuts frames out");
        expect(heard.silentAfterStart == 0, "clock drift never plays silence once sound started");
        const uint64_t slips = heard.skipped + heard.repeated;
        // 80 ppm of 10 min at 48 kHz is ~2300 frames to make up, one at a time.
        expect(slips > 1500 && slips < 4000, "the drift is made up one frame at a time");
        if (heard.cuts != 0 || heard.silentAfterStart != 0) {
            std::fprintf(stderr, "  drift %+.0f ppm: cuts=%llu longest=%llu silent=%llu slips=%llu\n",
                         drift * 1e6,
                         static_cast<unsigned long long>(heard.cuts),
                         static_cast<unsigned long long>(heard.longestCut),
                         static_cast<unsigned long long>(heard.silentAfterStart),
                         static_cast<unsigned long long>(slips));
        }
    }
}

void testDifferentBufferSizesWithDriftPlayWithoutCuts() {
    // The EQ device and the speakers rarely use the same IO buffer size.
    const Playback heard = playTwoClocks(48000.0, 512, 48000.0 * (1.0 + 50e-6), 441, 300.0);
    expect(heard.cuts == 0, "mismatched buffer sizes never cut frames out");
    expect(heard.silentAfterStart == 0, "mismatched buffer sizes never play silence");
}

void testLargeEQBuffersWithDriftPlayWithoutCuts() {
    // A client can run the EQ device with a 2048 or 4096 frame buffer: each
    // push then swings the fill by that much, and a fixed 2048-frame target ran
    // the ring dry at every low point.
    for (const size_t chunk : {size_t(2048), size_t(4096)}) {
        for (const double drift : {-50e-6, 50e-6}) {
            const Playback heard = playTwoClocks(48000.0, chunk, 48000.0 * (1.0 + drift), 512, 120.0);
            expect(heard.cuts == 0, "large EQ buffers never cut frames out");
            expect(heard.silentAfterStart == 0, "large EQ buffers never play silence once sound started");
            // Once settled it slips only what the drift needs: 50 ppm of the last
            // 90 s at 48 kHz is ~216 frames.
            expect(heard.slipsAfterWarmUp < 400, "large EQ buffers only slip what the drift needs once settled");
            if (heard.cuts != 0 || heard.silentAfterStart != 0 || heard.slipsAfterWarmUp >= 400) {
                std::fprintf(stderr, "  chunk %zu drift %+.0f ppm: cuts=%llu silent=%llu skipped=%llu repeated=%llu settled=%llu\n",
                             chunk, drift * 1e6,
                             static_cast<unsigned long long>(heard.cuts),
                             static_cast<unsigned long long>(heard.silentAfterStart),
                             static_cast<unsigned long long>(heard.skipped),
                             static_cast<unsigned long long>(heard.repeated),
                             static_cast<unsigned long long>(heard.slipsAfterWarmUp));
            }
        }
    }
}

void testAStoppedTargetStartsOverAtTheTargetFill() {
    // The target stops pulling for a second (unplugged, asleep): the ring
    // overruns, and when it comes back it plays the newest sound from the
    // target fill, not ~340 ms of stale audio.
    auto* ring = new EQRouterRing();
    EQRouterRing_Reset(ring);
    std::vector<float> in(512 * 2);
    std::vector<float> out(512 * 2);
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 2;
    list.mBuffers[0].mDataByteSize = static_cast<UInt32>(out.size() * sizeof(float));
    list.mBuffers[0].mData = out.data();
    uint64_t produced = 0;
    for (int i = 0; i < 100; ++i) {
        for (size_t f = 0; f < 512; ++f) encode(++produced, &in[f * 2]);
        EQRouterRing_Push(ring, in.data(), 512);
    }
    EQRouterRing_Pull(ring, &list);
    const uint64_t first = static_cast<uint64_t>(out[1]) * 4096 + static_cast<uint64_t>(out[0]);
    // The target fill plus half a push, so playback starts at once.
    expect(first == produced - (EQRouterRing_TargetFill(ring) + 512 / 2) + 1,
           "after an overrun the target resumes at the target fill with the newest sound");
    expect(ring->dropped_frames.load() == produced - kEQRouterRingFrames,
           "the overrun counts each lost frame once");
    delete ring;
}

void testZeroTimeStampsAdvanceAtTheDeviceRate() {
    // Before #590 every timestamp had StartIO's host time with the samples
    // elapsed since then: coreaudiod saw a device that never moved in time.
    EQZeroTimeStampClock clock;
    const double ticksPerSecond = 24.0e6;  // Apple silicon's mach timebase
    EQClock_Reset(&clock, 1000, ticksPerSecond, 48000.0);
    double previousSample = -1.0;
    uint64_t previousHost = 0;
    for (uint64_t now = 1000; now < 1000 + static_cast<uint64_t>(10.0 * ticksPerSecond); now += 7919) {
        double sample = 0;
        uint64_t host = 0;
        EQClock_ZeroTimeStamp(&clock, now, &sample, &host);
        expect(host <= now, "a zero timestamp is never in the future");
        expect(std::fmod(sample, kEQZeroTimeStampPeriod) == 0.0, "zero timestamps fall on period boundaries");
        if (previousSample >= 0.0 && sample != previousSample) {
            expect(sample - previousSample == kEQZeroTimeStampPeriod, "timestamps advance one period at a time");
            const double rate = (sample - previousSample) / (static_cast<double>(host - previousHost) / ticksPerSecond);
            expect(std::fabs(rate - 48000.0) < 1.0, "the host time between timestamps matches the device rate");
        }
        previousSample = sample;
        previousHost = host;
    }
    expect(previousSample >= 9.0 * 48000.0 - kEQZeroTimeStampPeriod, "ten seconds of timestamps cover ten seconds of samples");
}

void testTheEQDeviceFollowsEveryCommonOutputRate() {
    // Headsets in call mode, CD and video rates, high-rate DACs.
    for (const double rate : {8000.0, 16000.0, 24000.0, 32000.0, 44100.0, 48000.0, 88200.0, 96000.0,
                              176400.0, 192000.0, 352800.0, 384000.0}) {
        expect(EQClock_MatchingRate(rate, kEQSupportedSampleRates, kEQNumSupportedSampleRates) == rate,
               "the EQ device takes the target's rate");
    }
    expect(EQClock_MatchingRate(47999.0, kEQSupportedSampleRates, kEQNumSupportedSampleRates) == 0.0,
           "a rate the EQ device can't run at leaves it alone");
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

    testSameRateWithClockDriftPlaysWithoutCuts();
    testDifferentBufferSizesWithDriftPlayWithoutCuts();
    testAStoppedTargetStartsOverAtTheTargetFill();
    testZeroTimeStampsAdvanceAtTheDeviceRate();
    testLargeEQBuffersWithDriftPlayWithoutCuts();
    testTheEQDeviceFollowsEveryCommonOutputRate();

    if (gFailures == 0) {
        std::printf("driver router tests: all checks passed\n");
        return 0;
    }
    std::fprintf(stderr, "driver router tests: %d check(s) failed\n", gFailures);
    return 1;
}
