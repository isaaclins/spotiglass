import XCTest

@testable import Spotiglass

final class SpotifyDTOsCommonTests: XCTestCase {
    func testNilIfEmpty() {
        XCTAssertNil("".nilIfEmpty)
        XCTAssertEqual("x".nilIfEmpty, "x")
    }

    func testLargestImageURLPrefersWidestDimensions() throws {
        let json = """
            [
              { "url": "https://example.com/small.png", "width": 64, "height": 64 },
              { "url": "https://example.com/large.png", "width": 640, "height": 640 }
            ]
            """
        let images = try JSONDecoder().decode([SpotifyImageDTO].self, from: Data(json.utf8))
        XCTAssertEqual(images.largestImageURL?.absoluteString, "https://example.com/large.png")
    }

    func testLargestImageURLUsesHeightWhenWidthMissing() throws {
        let json = """
            [
              { "url": "https://example.com/a.png", "height": 10 },
              { "url": "https://example.com/b.png", "height": 200 }
            ]
            """
        let images = try JSONDecoder().decode([SpotifyImageDTO].self, from: Data(json.utf8))
        XCTAssertEqual(images.largestImageURL?.absoluteString, "https://example.com/b.png")
    }

    func testLargestImageURLEmptyArray() throws {
        let images = try JSONDecoder().decode([SpotifyImageDTO].self, from: Data("[]".utf8))
        XCTAssertNil(images.largestImageURL)
    }
}
