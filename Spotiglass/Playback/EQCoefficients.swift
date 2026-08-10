import Foundation

/// Shared layout between the GUI process and the bundled HAL plugin. The HAL
/// plugin reads this struct in its IO callback via a memory-mapped POSIX
/// shared-memory region. The 64-bit `sequence` field is the seqlock counter:
/// the writer makes it odd while writing, even when stable; the reader retries
/// while it sees odd, then re-reads `sequence` after the payload to detect a
/// torn read.
///
/// All fields are POD and use `Float32` so the C side can `memcpy` from the
/// shared region into a stack buffer in one cacheline-friendly read.
struct EQCoefficientFrame {
    /// 10 fixed-band biquads. Each band stores `{b0, b1, b2, a1, a2}`,
    /// normalised so `a0 = 1` and `b0/b1/b2` are pre-divided. The DSP loop is
    /// then a straight transposed direct-form-II:
    ///   y = b0*x + b1*x_z1 + b2*x_z2 - a1*y_z1 - a2*y_z2
    static let bandCount = EqualizerSettings.bandCount
    static let coeffsPerBand = 5

    var sequence: UInt64
    var preampLinear: Float
    var bands: [Float]  // length = bandCount * coeffsPerBand
    var sampleRateHz: UInt32
    var enabledMask: UInt32

    init(
        sequence: UInt64 = 0,
        preampLinear: Float = 1.0,
        bands: [Float] = Array(repeating: 0, count: Self.bandCount * Self.coeffsPerBand),
        sampleRateHz: UInt32 = 48_000,
        enabledMask: UInt32 = 0xFFFF_FFFF
    ) {
        self.sequence = sequence
        self.preampLinear = preampLinear
        self.bands = bands
        self.sampleRateHz = sampleRateHz
        self.enabledMask = enabledMask
    }

    /// Translates an ``EqualizerSettings`` curve into the binary coefficient
    /// layout expected by the HAL plugin. Coefficients are derived from
    /// Robert Bristow-Johnson's audio EQ cookbook formulas: low-shelf for
    /// the lowest band, high-shelf for the highest, peaking EQ for the eight
    /// middle bands. Q values are chosen for musical-sounding 1-octave bands.
    static func build(settings: EqualizerSettings, sampleRateHz: UInt32) -> EQCoefficientFrame {
        let preampLinear = Self.dbToLinear(settings.preamp)
        var flat = [Float](repeating: 0, count: Self.bandCount * Self.coeffsPerBand)
        for (index, gainDb) in settings.bands.enumerated() {
            let center = EqualizerSettings.bandFrequenciesHz[index]
            let kind: BiquadKind
            if index == 0 {
                kind = .lowShelf
            } else if index == Self.bandCount - 1 {
                kind = .highShelf
            } else {
                kind = .peaking(q: 1.0)
            }
            let coeffs = Self.biquad(
                kind: kind,
                centerHz: center,
                gainDb: gainDb,
                sampleRateHz: Double(sampleRateHz)
            )
            let base = index * Self.coeffsPerBand
            flat[base + 0] = Float(coeffs.b0)
            flat[base + 1] = Float(coeffs.b1)
            flat[base + 2] = Float(coeffs.b2)
            flat[base + 3] = Float(coeffs.a1)
            flat[base + 4] = Float(coeffs.a2)
        }
        return EQCoefficientFrame(
            sequence: 0,
            preampLinear: Float(preampLinear),
            bands: flat,
            sampleRateHz: sampleRateHz,
            enabledMask: settings.enabled ? 0xFFFF_FFFF : 0
        )
    }

    /// Bypass identity for an N-band biquad cascade: `y = preamp * x`, no
    /// filtering. Used by the bypass A/B comparison test.
    static func bypass(sampleRateHz: UInt32) -> EQCoefficientFrame {
        var flat = [Float](repeating: 0, count: Self.bandCount * Self.coeffsPerBand)
        for index in 0..<Self.bandCount {
            let base = index * Self.coeffsPerBand
            flat[base + 0] = 1  // b0
            // b1, b2, a1, a2 all zero -> identity filter
        }
        return EQCoefficientFrame(
            sequence: 0,
            preampLinear: 1.0,
            bands: flat,
            sampleRateHz: sampleRateHz,
            enabledMask: 0
        )
    }

    // MARK: - Biquad math

    enum BiquadKind {
        case peaking(q: Double)
        case lowShelf
        case highShelf
    }

    struct BiquadCoeffs: Equatable {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
    }

    /// RBJ audio EQ cookbook. `gainDb` is the peak/shelf gain in dB; positive
    /// values lift, negative cut, zero gives an identity-coefficient set that
    /// reduces to passthrough. All shelves default to S=1 (no overshoot).
    static func biquad(
        kind: BiquadKind,
        centerHz: Double,
        gainDb: Double,
        sampleRateHz: Double
    ) -> BiquadCoeffs {
        // 0 dB shortcut keeps the cascade bit-exact identity at flat positions.
        if abs(gainDb) < 1e-9 {
            return BiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        }
        let A = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * .pi * centerHz / sampleRateHz
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double
        switch kind {
        case .peaking(let q):
            let alpha = sinW0 / (2.0 * q)
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A
        case .lowShelf:
            // S=1 -> alpha = sin(w0)/2 * sqrt((A + 1/A)*(1/S - 1) + 2). With S=1: alpha = sin(w0)/2 * sqrt(2).
            let alpha = sinW0 / 2.0 * sqrt(2.0)
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW0)
            b2 = A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW0)
            a2 = (A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha
        case .highShelf:
            let alpha = sinW0 / 2.0 * sqrt(2.0)
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2 = A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW0)
            a2 = (A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha
        }
        return BiquadCoeffs(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }

    static func dbToLinear(_ dB: Double) -> Double { pow(10.0, dB / 20.0) }
}
