import XCTest
@testable import Spotiglass

final class EqualizerPresetsTests: XCTestCase {
    private let expectedBuiltInNames: [String] = [
        "Flat",
        "Bass Boost",
        "Vocal",
        "Treble Boost",
        "Acoustic",
        "Electronic",
        "Loudness",
    ]

    func testBuiltInPresetsExposeAllExpectedNames() {
        let names = EqualizerPreset.builtIns.map(\.name)
        XCTAssertEqual(names, expectedBuiltInNames)
    }

    func testBuiltInPresetsAllUseTenBandsClampedToRange() {
        for preset in EqualizerPreset.builtIns {
            XCTAssertEqual(preset.bands.count, EqualizerSettings.bandCount, "Preset \(preset.name) should have 10 bands")
            for (index, value) in preset.bands.enumerated() {
                XCTAssertTrue(
                    EqualizerSettings.gainRangeDB.contains(value),
                    "Preset \(preset.name) band[\(index)] = \(value) outside \(EqualizerSettings.gainRangeDB)"
                )
            }
        }
    }

    func testFlatPresetIsAllZeros() {
        XCTAssertEqual(EqualizerPreset.flat.name, "Flat")
        XCTAssertEqual(EqualizerPreset.flat.bands, Array(repeating: 0, count: EqualizerSettings.bandCount))
        XCTAssertEqual(EqualizerPreset.flat.preamp, 0)
    }

    func testEqualizerInitializerClampsPreampToRange() {
        XCTAssertEqual(
            EqualizerSettings(preamp: 100).preamp,
            EqualizerSettings.preampRangeDB.upperBound
        )
        XCTAssertEqual(
            EqualizerSettings(preamp: -100).preamp,
            EqualizerSettings.preampRangeDB.lowerBound
        )
        XCTAssertEqual(EqualizerSettings(preamp: 3.5).preamp, 3.5)
    }

    func testApplyPresetUpdatesBandsPreampAndActiveName() {
        var settings = EqualizerSettings()
        let preset = EqualizerPreset(name: "Custom", preamp: -1, bands: [3, 2, 1, 0, -1, -2, -3, 0, 0, 0])

        settings.apply(preset: preset)

        XCTAssertEqual(settings.bands, preset.bands)
        XCTAssertEqual(settings.preamp, preset.preamp)
        XCTAssertEqual(settings.activePresetName, "Custom")
        XCTAssertTrue(settings.matches(preset))
    }

    func testFindLooksAtUserPresetsBeforeReturningNil() {
        let userPreset = EqualizerPreset(name: "My Curve", preamp: 0, bands: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1])
        XCTAssertNotNil(EqualizerPreset.find(named: "Bass Boost", userPresets: []))
        XCTAssertNotNil(EqualizerPreset.find(named: "My Curve", userPresets: [userPreset]))
        XCTAssertNil(EqualizerPreset.find(named: "Nonexistent", userPresets: [userPreset]))
    }

    func testEncodingIsStableAcrossRoundTrip() throws {
        for preset in EqualizerPreset.builtIns {
            let encoded = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(EqualizerPreset.self, from: encoded)
            XCTAssertEqual(decoded, preset)
        }
    }

    func testNormalizedBandsPadsAndClamps() {
        let padded = EqualizerSettings.normalizedBands([3, 2])
        XCTAssertEqual(padded.count, EqualizerSettings.bandCount)
        XCTAssertEqual(padded.prefix(2).map { $0 }, [3, 2])
        XCTAssertEqual(padded.suffix(EqualizerSettings.bandCount - 2).map { $0 }, Array(repeating: 0, count: EqualizerSettings.bandCount - 2))

        let clamped = EqualizerSettings.normalizedBands([100, -100, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(clamped[0], EqualizerSettings.gainRangeDB.upperBound)
        XCTAssertEqual(clamped[1], EqualizerSettings.gainRangeDB.lowerBound)
    }
}
