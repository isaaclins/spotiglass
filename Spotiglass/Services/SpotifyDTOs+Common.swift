import Foundation

extension Array where Element == SpotifyImageDTO {
    var largestImageURL: URL? {
        sorted { lhs, rhs in
            (lhs.width ?? lhs.height ?? 0) > (rhs.width ?? rhs.height ?? 0)
        }
        .first?
        .url
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

