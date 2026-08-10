import XCTest

@testable import Spotiglass

/// Verifies the writer side of the GUI → HAL-plugin shared-memory IPC. The
/// real HAL plugin reads the same backing file by mmap inside its IO callback;
/// these tests stand in for that consumer so the seqlock writer protocol is
/// exercisable in CI without spinning up coreaudiod.
final class EQCoefficientPublisherTests: XCTestCase {
    private var tmpPath: String!
    private var publisher: EQCoefficientPublisher!

    override func setUp() {
        super.setUp()
        tmpPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("spotiglass-eq-\(UUID().uuidString).shm")
        publisher = EQCoefficientPublisher(shmPath: tmpPath)
    }

    override func tearDown() {
        publisher = nil
        try? FileManager.default.removeItem(atPath: tmpPath)
        super.tearDown()
    }

    /// A round-trip writes a frame and reads back the same payload via the
    /// test-only reader. Catches struct-layout drift in either direction.
    func testWriterRoundTripReadsBackSameFrame() {
        let original = EQCoefficientFrame(
            sequence: 0,
            preampLinear: 0.7079457,  // -3 dB
            bands: (0..<(EQCoefficientFrame.bandCount * EQCoefficientFrame.coeffsPerBand)).map { Float($0) * 0.1 },
            sampleRateHz: 96_000,
            enabledMask: 0xFFFF_FFFF
        )
        publisher.write(original)
        guard let readBack = publisher.readForTesting() else {
            return XCTFail("publisher returned no frame")
        }
        XCTAssertEqual(readBack.preampLinear, original.preampLinear, accuracy: 1e-7)
        XCTAssertEqual(readBack.bands.count, original.bands.count)
        for (a, b) in zip(readBack.bands, original.bands) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
        XCTAssertEqual(readBack.sampleRateHz, original.sampleRateHz)
        XCTAssertEqual(readBack.enabledMask, original.enabledMask)
    }

    /// Sequence numbers must be even when at rest. The writer makes them odd
    /// mid-write and even when stable; a consumer that sees an odd sequence
    /// retries. Reading after every write should always observe an even seq.
    func testSequenceIsEvenAfterEveryWrite() {
        let frame = EQCoefficientFrame.bypass(sampleRateHz: 48_000)
        for _ in 0..<8 {
            publisher.write(frame)
            let seq = publisher.readForTesting()?.sequence ?? .max
            XCTAssertEqual(seq % 2, 0, "post-write sequence must be even")
        }
    }

    /// Sequence numbers must strictly increase. Verifies the writer always
    /// publishes a fresh seqlock value even when the payload is identical, so
    /// a consumer that only watches `sequence` still sees activity.
    func testSequenceMonotonicallyIncreasesAcrossWrites() {
        let frame = EQCoefficientFrame.bypass(sampleRateHz: 48_000)
        publisher.write(frame)
        let first = publisher.readForTesting()?.sequence ?? 0
        publisher.write(frame)
        let second = publisher.readForTesting()?.sequence ?? 0
        publisher.write(frame)
        let third = publisher.readForTesting()?.sequence ?? 0
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, third)
    }
}
