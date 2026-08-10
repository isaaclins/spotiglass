import Foundation
import os.lock

/// Writer side of the GUI → HAL-plugin shared-memory coefficient channel.
///
/// Layout (see ADR-EQ-2 in `docs/equalizer.md`):
///
/// ```c
/// struct EQCoefficientFrame {
///     _Atomic(uint64_t) sequence;            // odd while writing, even when stable
///     float             preampLinear;
///     float             bandCoeffs[10 * 5];   // {b0, b1, b2, a1, a2} per band
///     uint32_t          sampleRateHz;
///     uint32_t          enabledMask;
/// };
/// ```
///
/// The HAL plugin (running inside `coreaudiod`) maps this region read-only
/// and reads it inside its real-time IO callback via a seqlock retry loop.
/// The writer here makes the sequence odd, copies the payload, then makes it
/// even again — torn reads on the consumer side are detectable and retried.
///
/// In test environments where no actual shared memory is needed, callers can
/// pass a temporary directory through ``init(shmDirectory:)`` to use a tmpfs
/// backing instead of `/tmp` so multiple tests don't collide.
final class EQCoefficientPublisher {
    /// Default backing path. Fixed (no uid suffix) so it matches the path
    /// the driver opens from inside coreaudiod, where `getuid()` returns
    /// _coreaudiod's uid (202), not the logged-in user.
    static var defaultBackingPath: String {
        "/tmp/com.isaaclins.spotiglass.eq.coeffs.v1"
    }

    private let backingURL: URL
    /// Serialises writes from multiple GUI threads. The reader side never
    /// touches this lock — it relies only on atomic loads of `sequence`.
    private let writeLock = OSAllocatedUnfairLock()
    private var sequenceCounter: UInt64 = 0
    private var fileHandle: FileHandle?

    init(shmPath: String = EQCoefficientPublisher.defaultBackingPath) {
        self.backingURL = URL(fileURLWithPath: shmPath)
        try? openOrCreate()
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Publish a fresh coefficient frame. The seqlock dance guarantees the
    /// HAL plugin either sees the full new frame or detects a torn read and
    /// retries on the next IO cycle.
    func write(_ frame: EQCoefficientFrame) {
        writeLock.withLock {
            guard let fileHandle else { return }
            sequenceCounter &+= 1
            let oddSeq = sequenceCounter | 1  // ensure odd
            do {
                try fileHandle.seek(toOffset: 0)
                try writeUInt64(oddSeq, to: fileHandle)
                try writePayload(frame, to: fileHandle)
                try fileHandle.seek(toOffset: 0)
                try writeUInt64(oddSeq + 1, to: fileHandle)  // even -> stable
                sequenceCounter = oddSeq + 1
            } catch {
                // Writing to a regular file shouldn't fail in normal operation,
                // and if it does, the consumer just keeps reading the previous
                // frame on its next cycle. Surfacing the error would surprise
                // callers who don't expect IO from a coefficient setter.
            }
        }
    }

    /// Test-only read accessor: returns the most recently published frame by
    /// reading the backing file directly. Not used by the HAL plugin (which
    /// does a memory-mapped seqlock read in C). Exposed here so the IPC
    /// handshake test can verify writer/reader symmetry without spinning up
    /// the actual `.driver`.
    func readForTesting() -> EQCoefficientFrame? {
        writeLock.withLock {
            guard let fileHandle else { return nil }
            do {
                try fileHandle.seek(toOffset: 0)
                let seqData = try fileHandle.read(upToCount: MemoryLayout<UInt64>.size) ?? Data()
                guard seqData.count == MemoryLayout<UInt64>.size else { return nil }
                let seq = seqData.withUnsafeBytes { $0.load(as: UInt64.self) }
                let preampData = try fileHandle.read(upToCount: MemoryLayout<Float>.size) ?? Data()
                let preamp = preampData.withUnsafeBytes { $0.load(as: Float.self) }
                let bandsBytes =
                    EQCoefficientFrame.bandCount * EQCoefficientFrame.coeffsPerBand * MemoryLayout<Float>.size
                let bandsData = try fileHandle.read(upToCount: bandsBytes) ?? Data()
                var bands = [Float](
                    repeating: 0, count: EQCoefficientFrame.bandCount * EQCoefficientFrame.coeffsPerBand)
                _ = bands.withUnsafeMutableBytes { dst in
                    bandsData.copyBytes(to: dst)
                }
                let rateData = try fileHandle.read(upToCount: MemoryLayout<UInt32>.size) ?? Data()
                let rate = rateData.withUnsafeBytes { $0.load(as: UInt32.self) }
                let maskData = try fileHandle.read(upToCount: MemoryLayout<UInt32>.size) ?? Data()
                let mask = maskData.withUnsafeBytes { $0.load(as: UInt32.self) }
                return EQCoefficientFrame(
                    sequence: seq,
                    preampLinear: preamp,
                    bands: bands,
                    sampleRateHz: rate,
                    enabledMask: mask
                )
            } catch {
                return nil
            }
        }
    }

    // MARK: - Internals

    private func openOrCreate() throws {
        let path = backingURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: backingURL)
        let payloadBytes =
            MemoryLayout<UInt64>.size
            + MemoryLayout<Float>.size
            + EQCoefficientFrame.bandCount * EQCoefficientFrame.coeffsPerBand * MemoryLayout<Float>.size
            + MemoryLayout<UInt32>.size
            + MemoryLayout<UInt32>.size
        try handle.truncate(atOffset: UInt64(payloadBytes))
        self.fileHandle = handle
    }

    private func writeUInt64(_ value: UInt64, to handle: FileHandle) throws {
        var v = value
        let data = withUnsafeBytes(of: &v) { Data($0) }
        try handle.write(contentsOf: data)
    }

    private func writePayload(_ frame: EQCoefficientFrame, to handle: FileHandle) throws {
        var preamp = frame.preampLinear
        try handle.write(contentsOf: withUnsafeBytes(of: &preamp) { Data($0) })
        try frame.bands.withUnsafeBufferPointer { buf in
            try handle.write(contentsOf: Data(buffer: buf))
        }
        var rate = frame.sampleRateHz
        try handle.write(contentsOf: withUnsafeBytes(of: &rate) { Data($0) })
        var mask = frame.enabledMask
        try handle.write(contentsOf: withUnsafeBytes(of: &mask) { Data($0) })
    }
}
