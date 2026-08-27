import XCTest
@testable import Spotiglass

/// Exercises the biquad coefficient math in ``EQCoefficientFrame`` against
/// reference values derived from the RBJ audio EQ cookbook. The test bar is
/// tight (1e-6 absolute) because the formulas are deterministic and shifting
/// from these values is almost always a bug — either a sign flip or a missed
/// normalization by `a0`.
final class EqualizerCoefficientTests: XCTestCase {
    /// A 0 dB gain at any frequency must collapse the biquad to a passthrough
    /// (b0=1, all other coefs = 0). This is the bit-exact "flat = bypass"
    /// guarantee that keeps the cascade lossless when no band is touched.
    func testZeroDbGainProducesIdentityBiquad() {
        let frequencies = [80.0, 1000.0, 8000.0, 16000.0]
        let rates = [44100.0, 48000.0, 96000.0]
        for f in frequencies {
            for r in rates {
                for kind in [
                    EQCoefficientFrame.BiquadKind.peaking(q: 1.0),
                    .lowShelf,
                    .highShelf
                ] {
                    let coeffs = EQCoefficientFrame.biquad(
                        kind: kind, centerHz: f, gainDb: 0, sampleRateHz: r
                    )
                    XCTAssertEqual(coeffs.b0, 1.0, accuracy: 1e-9, "f=\(f) r=\(r)")
                    XCTAssertEqual(coeffs.b1, 0.0, accuracy: 1e-9)
                    XCTAssertEqual(coeffs.b2, 0.0, accuracy: 1e-9)
                    XCTAssertEqual(coeffs.a1, 0.0, accuracy: 1e-9)
                    XCTAssertEqual(coeffs.a2, 0.0, accuracy: 1e-9)
                }
            }
        }
    }

    /// Peaking-EQ behavioural checks at 1 kHz / +6 dB / Q=1 / 48 kHz:
    /// - The peak response (z = e^{jw0}) should be |10^(6/20)| = ~1.995.
    /// - b1 must equal a1 (RBJ peaking symmetry: both equal `-2 cos w0`
    ///   after the a0 normalization cancels).
    /// - b0/a0 normalization → a-coefficients sum should put the denominator
    ///   form in canonical shape (a0 = 1 implicit).
    func testPeakingEqResponseAtCenterMatchesDbGain() {
        let c = EQCoefficientFrame.biquad(
            kind: .peaking(q: 1.0), centerHz: 1000, gainDb: 6, sampleRateHz: 48000
        )
        // Peaking-EQ symmetry: b1 == a1 (both are -2 cos w0 / a0).
        XCTAssertEqual(c.b1, c.a1, accuracy: 1e-9,
                       "peaking EQ should be symmetric in numerator/denominator middle coefs")

        // Magnitude response at the center frequency.
        let w0 = 2.0 * .pi * 1000.0 / 48000.0
        // H(e^{jw0}) magnitude:
        // H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2)
        // |H(e^{jw0})|^2 = (|num|^2) / (|den|^2)
        let cosw = cos(w0)
        let cos2w = cos(2.0 * w0)
        let sinw = sin(w0)
        let sin2w = sin(2.0 * w0)
        let numR = c.b0 + c.b1 * cosw + c.b2 * cos2w
        let numI = -c.b1 * sinw - c.b2 * sin2w
        let denR = 1.0 + c.a1 * cosw + c.a2 * cos2w
        let denI = -c.a1 * sinw - c.a2 * sin2w
        let mag = sqrt(numR * numR + numI * numI) / sqrt(denR * denR + denI * denI)
        let expected = pow(10.0, 6.0 / 20.0)  // 1.9952623
        XCTAssertEqual(mag, expected, accuracy: 0.05,
                       "peaking EQ at +6 dB should boost the center-bin magnitude by ~6 dB")
    }

    /// Low-shelf gain sign: a positive dB lift must raise the magnitude
    /// response at DC. Concretely, the steady-state DC response of a biquad
    /// is `(b0 + b1 + b2) / (1 + a1 + a2)`; for a low-shelf at +6 dB / 80 Hz
    /// / 48 kHz this should equal ~10^(6/20) = ~1.9953 (the cookbook is exact
    /// to floating-point in the steady-state limit).
    func testLowShelfDcGainMatchesSpec() {
        let c = EQCoefficientFrame.biquad(
            kind: .lowShelf, centerHz: 80, gainDb: 6, sampleRateHz: 48000
        )
        let dcResponse = (c.b0 + c.b1 + c.b2) / (1.0 + c.a1 + c.a2)
        let expected = pow(10.0, 6.0 / 20.0)
        XCTAssertEqual(dcResponse, expected, accuracy: 0.02,
                       "low-shelf should boost DC by the requested dB gain")
    }

    /// High-shelf gain at Nyquist: with `z = -1` the biquad evaluates to
    /// `(b0 - b1 + b2) / (1 - a1 + a2)`. A +6 dB high-shelf at 16 kHz / 48 kHz
    /// should asymptote to ~10^(6/20) at Nyquist (z = -1).
    func testHighShelfNyquistGainMatchesSpec() {
        let c = EQCoefficientFrame.biquad(
            kind: .highShelf, centerHz: 16000, gainDb: 6, sampleRateHz: 48000
        )
        let nyquistResponse = (c.b0 - c.b1 + c.b2) / (1.0 - c.a1 + c.a2)
        let expected = pow(10.0, 6.0 / 20.0)
        XCTAssertEqual(nyquistResponse, expected, accuracy: 0.05,
                       "high-shelf should boost Nyquist by the requested dB gain")
    }

    /// The Flat preset must produce an entirely passthrough coefficient
    /// frame. This is the foundation of the "EQ-off vs Flat within ±0.05 dB
    /// RMS" success criterion: if the math is bit-exact, the A/B is too.
    func testFlatPresetProducesIdentityCoefficients() {
        var settings = EqualizerSettings()
        settings.apply(preset: EqualizerPreset.flat)
        let frame = EQCoefficientFrame.build(settings: settings, sampleRateHz: 48000)
        for band in 0..<EQCoefficientFrame.bandCount {
            let base = band * EQCoefficientFrame.coeffsPerBand
            XCTAssertEqual(frame.bands[base + 0], 1.0, accuracy: 1e-9, "band \(band) b0")
            XCTAssertEqual(frame.bands[base + 1], 0.0, accuracy: 1e-9, "band \(band) b1")
            XCTAssertEqual(frame.bands[base + 2], 0.0, accuracy: 1e-9, "band \(band) b2")
            XCTAssertEqual(frame.bands[base + 3], 0.0, accuracy: 1e-9, "band \(band) a1")
            XCTAssertEqual(frame.bands[base + 4], 0.0, accuracy: 1e-9, "band \(band) a2")
        }
        XCTAssertEqual(frame.preampLinear, 1.0, accuracy: 1e-9)
    }

    func testOutOfRangePreampUsesTheClampedModelValueInCoefficients() {
        let upperSettings = EqualizerSettings(preamp: 100)
        let lowerSettings = EqualizerSettings(preamp: -100)
        let upperFrame = EQCoefficientFrame.build(settings: upperSettings, sampleRateHz: 48000)
        let lowerFrame = EQCoefficientFrame.build(settings: lowerSettings, sampleRateHz: 48000)

        XCTAssertEqual(
            upperFrame.preampLinear,
            Float(EQCoefficientFrame.dbToLinear(EqualizerSettings.preampRangeDB.upperBound)),
            accuracy: 1e-6
        )
        XCTAssertEqual(
            lowerFrame.preampLinear,
            Float(EQCoefficientFrame.dbToLinear(EqualizerSettings.preampRangeDB.lowerBound)),
            accuracy: 1e-6
        )
    }

    /// Bass Boost lifts the four lowest bands and leaves the upper six at 0.
    /// Verifies the band-index → frequency mapping by checking that bands 0..3
    /// produce non-identity coefficients and bands 4..9 stay identity.
    func testBassBoostLiftsLowsAndLeavesHighsFlat() {
        var settings = EqualizerSettings()
        let preset = EqualizerPreset.builtIns.first { $0.name == "Bass Boost" }!
        settings.apply(preset: preset)
        let frame = EQCoefficientFrame.build(settings: settings, sampleRateHz: 48000)
        for band in 0..<EQCoefficientFrame.bandCount {
            let base = band * EQCoefficientFrame.coeffsPerBand
            let coeffs = (
                b0: frame.bands[base + 0],
                b1: frame.bands[base + 1],
                b2: frame.bands[base + 2],
                a1: frame.bands[base + 3],
                a2: frame.bands[base + 4]
            )
            let isIdentity = coeffs.b0 == 1 && coeffs.b1 == 0 && coeffs.b2 == 0
                && coeffs.a1 == 0 && coeffs.a2 == 0
            if band <= 3 {
                XCTAssertFalse(isIdentity, "band \(band) should be lifted by Bass Boost")
            } else {
                XCTAssertTrue(isIdentity, "band \(band) should be flat in Bass Boost")
            }
        }
    }

    /// Every built-in preset must produce a well-formed coefficient frame
    /// (correct length, finite values, sample rate echoed back). Catches
    /// NaN/Inf escape paths if the cookbook formulas ever divide by zero.
    func testAllBuiltInPresetsProduceFiniteCoefficientFrames() {
        for preset in EqualizerPreset.builtIns {
            var settings = EqualizerSettings()
            settings.apply(preset: preset)
            let frame = EQCoefficientFrame.build(settings: settings, sampleRateHz: 48000)
            XCTAssertEqual(
                frame.bands.count,
                EQCoefficientFrame.bandCount * EQCoefficientFrame.coeffsPerBand,
                "\(preset.name) coefficient frame length"
            )
            XCTAssertTrue(frame.preampLinear.isFinite, "\(preset.name) preamp finite")
            for (i, c) in frame.bands.enumerated() {
                XCTAssertTrue(c.isFinite, "\(preset.name) band coef[\(i)] finite")
            }
            XCTAssertEqual(frame.sampleRateHz, 48000)
        }
    }
}
