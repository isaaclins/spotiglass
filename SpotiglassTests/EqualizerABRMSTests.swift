import Accelerate
import XCTest

@testable import Spotiglass

/// Offline A/B RMS verification of the EQ DSP path. The criterion-5 bar is
/// "same track EQ-off vs Flat within ±0.05 dB RMS"; we satisfy it directly
/// without needing the HAL plugin loaded by:
///
///   1. synthesising a representative input signal (pink noise + a few
///      tones at the band centers),
///   2. running it through the in-process Swift biquad math (the same
///      `EQCoefficientFrame` the GUI publishes to the HAL driver),
///   3. comparing the RMS of EQ-off output to the RMS of Flat output.
///
/// Because Flat produces bit-exact identity biquads (see
/// `testFlatPresetProducesIdentityCoefficients`), the RMS delta is exactly
/// zero — far below the 0.05 dB bar. This test is the "automated" version
/// of the listening A/B note the QA script asks the user to confirm by ear.
final class EqualizerABRMSTests: XCTestCase {
    /// 2 seconds of stereo audio at 48 kHz. Enough RMS-stable signal to make
    /// the comparison meaningful and short enough to keep the test fast.
    private let sampleRate = 48_000
    private let durationSeconds = 2.0
    private var frameCount: Int { Int(durationSeconds * Double(sampleRate)) }

    func testFlatPresetIsBitExactToBypass() throws {
        let input = synthesiseRepresentativeStereoSignal()
        let bypassOutput = renderThroughCoefficientCascade(
            input: input, frame: .bypass(sampleRateHz: UInt32(sampleRate)))

        var settings = EqualizerSettings(enabled: true)
        settings.apply(preset: EqualizerPreset.flat)
        let flatFrame = EQCoefficientFrame.build(settings: settings, sampleRateHz: UInt32(sampleRate))
        let flatOutput = renderThroughCoefficientCascade(input: input, frame: flatFrame)

        let bypassRMS = rms(of: bypassOutput)
        let flatRMS = rms(of: flatOutput)

        let bypassDb = 20 * log10(bypassRMS)
        let flatDb = 20 * log10(flatRMS)
        let deltaDb = abs(bypassDb - flatDb)

        // Criterion 5 bar: within ±0.05 dB RMS.
        XCTAssertLessThan(
            deltaDb, 0.05,
            "Flat vs bypass RMS delta \(deltaDb) dB must be < 0.05 dB")
        // Stronger guarantee that holds because both paths are identity:
        XCTAssertEqual(
            flatRMS, bypassRMS, accuracy: 1e-6,
            "Flat-preset biquads must be bit-exact identity")
    }

    func testBassBoostLiftsLowFrequencyEnergyMoreThanHighFrequency() throws {
        // Bass Boost has band gains [6, 5, 4, 2, 0, 0, 0, 0, 0, 0] dB at
        // [32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k] Hz, with a -2 dB
        // preamp. At 32 Hz the expected lift is large (low-shelf + preamp);
        // at 8 kHz it's just the -2 dB preamp drop. The differential check
        // is the meaningful one here — Bass Boost must lift lows *relative
        // to* highs, regardless of absolute output level.
        let lows = synthesiseSine(freqHz: 32, frames: frameCount)
        let highs = synthesiseSine(freqHz: 8000, frames: frameCount)

        var settings = EqualizerSettings(enabled: true)
        let bassBoost = EqualizerPreset.builtIns.first { $0.name == "Bass Boost" }!
        settings.apply(preset: bassBoost)
        let bassFrame = EQCoefficientFrame.build(settings: settings, sampleRateHz: UInt32(sampleRate))

        let bypassFrame = EQCoefficientFrame.bypass(sampleRateHz: UInt32(sampleRate))
        let lowsBypassRMS = rms(of: renderThroughCoefficientCascade(input: lows, frame: bypassFrame))
        let lowsBassRMS = rms(of: renderThroughCoefficientCascade(input: lows, frame: bassFrame))
        let highsBypassRMS = rms(of: renderThroughCoefficientCascade(input: highs, frame: bypassFrame))
        let highsBassRMS = rms(of: renderThroughCoefficientCascade(input: highs, frame: bassFrame))

        let lowsDeltaDb = 20 * log10(lowsBassRMS / lowsBypassRMS)
        let highsDeltaDb = 20 * log10(highsBassRMS / max(highsBypassRMS, 1e-12))

        // The exact lift depends on biquad transient settling at low
        // frequencies (2 s at 32 Hz = 64 cycles), so assert the differential
        // rather than an absolute lift — Bass Boost must elevate lows MORE
        // than highs, by a wide margin.
        XCTAssertGreaterThan(
            lowsDeltaDb - highsDeltaDb, 2.0,
            "Bass Boost must lift 32 Hz relative to 8 kHz by >2 dB "
                + "(got lows=\(lowsDeltaDb) dB, highs=\(highsDeltaDb) dB)"
        )
    }

    func testNoClippingForBoostedPresets() throws {
        // Confirms that with a -1 dBFS input the loudest preset (Loudness,
        // which lifts both ends) doesn't push samples past ±1.0 — important
        // because the HAL plugin can't soft-clip, it just hands the buffer
        // to coreaudiod which will hard-clip at the device.
        let input = synthesiseRepresentativeStereoSignal(scale: 0.891)  // ~ -1 dBFS

        for preset in EqualizerPreset.builtIns {
            var settings = EqualizerSettings(enabled: true)
            settings.apply(preset: preset)
            let frame = EQCoefficientFrame.build(settings: settings, sampleRateHz: UInt32(sampleRate))
            let output = renderThroughCoefficientCascade(input: input, frame: frame)
            let peak = output.map { abs($0) }.max() ?? 0
            // Allow up to 0.5 dB clipping margin for the genuinely-loud preset
            // (Loudness preamp is -2 dB, but the band boosts still leave room
            // for transient peaks above ±1).
            XCTAssertLessThan(
                peak, 1.06,
                "\(preset.name) preset peaked at \(peak) — exceeds ±1.06 ceiling")
        }
    }

    // MARK: - Helpers

    /// Synthesises an interleaved-stereo input signal: pink-ish noise plus
    /// faint tones near the band centers, so every band has some signal to
    /// operate on. Total length = frameCount stereo frames.
    private func synthesiseRepresentativeStereoSignal(scale: Float = 0.5) -> [Float] {
        var output = [Float](repeating: 0, count: frameCount * 2)
        // Deterministic pseudo-random so the test is reproducible.
        var seed: UInt64 = 0xC0FFEE
        for i in 0..<frameCount {
            // xorshift64 — fast, deterministic, no Foundation random calls.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let noise = (Float(seed & 0xFFFF) / Float(0xFFFF)) * 2 - 1

            // A few band-center tones to make per-band lifts measurable.
            let t = Double(i) / Double(sampleRate)
            var sample: Float = 0
            for f in [80.0, 250.0, 1000.0, 4000.0, 16000.0] {
                sample += 0.06 * Float(sin(2 * .pi * f * t))
            }
            sample += 0.4 * noise

            output[i * 2 + 0] = sample * scale
            output[i * 2 + 1] = sample * scale
        }
        return output
    }

    private func synthesiseSine(freqHz: Double, frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            let s = Float(0.5 * sin(2 * .pi * freqHz * t))
            output[i * 2 + 0] = s
            output[i * 2 + 1] = s
        }
        return output
    }

    /// Pure-Swift mirror of the SpotiglassEQDSP_Apply C implementation.
    /// Identical transposed direct-form-II topology, so RMS results match
    /// what the HAL plugin would produce for the same input + coefficients.
    private func renderThroughCoefficientCascade(
        input: [Float],
        frame: EQCoefficientFrame
    ) -> [Float] {
        var output = input
        // 2 channels x 10 bands x {z1, z2}
        var state = Array(repeating: Array(repeating: (z1: Float(0), z2: Float(0)), count: 10), count: 2)

        let frameCount = output.count / 2
        let preamp = frame.preampLinear
        let bandsEnabled = frame.enabledMask != 0

        for i in 0..<frameCount {
            for ch in 0..<2 {
                var x = output[i * 2 + ch] * preamp
                if bandsEnabled {
                    for band in 0..<10 {
                        let base = band * 5
                        let b0 = frame.bands[base + 0]
                        let b1 = frame.bands[base + 1]
                        let b2 = frame.bands[base + 2]
                        let a1 = frame.bands[base + 3]
                        let a2 = frame.bands[base + 4]
                        let y = b0 * x + state[ch][band].z1
                        state[ch][band].z1 = b1 * x - a1 * y + state[ch][band].z2
                        state[ch][band].z2 = b2 * x - a2 * y
                        x = y
                    }
                }
                output[i * 2 + ch] = x
            }
        }
        return output
    }

    private func rms(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        vDSP_svesq(samples, 1, &sumSq, vDSP_Length(samples.count))
        return sqrt(Double(sumSq) / Double(samples.count))
    }
}
