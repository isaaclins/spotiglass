import Foundation

/// Keeps a copy of a file the app could not fully read before anything is written over it.
///
/// Settings, shortcuts and pins fall back to what they can read when a file is damaged or
/// comes from a newer build. Saving that fallback used to replace the original for good, so
/// one bad entry cost every setting or pin (#597). The bytes are copied next to the file as
/// `<name>.unreadable-<date>.<ext>` first; a save that cannot make the copy does not happen.
enum UnreadableFileBackup {
    /// Copies kept per file. Older ones are deleted when a new one is made, so a file that
    /// keeps failing cannot fill the disk.
    static let keptCopies = 5

    private static let marker = ".unreadable-"

    /// Writes `data` next to `url` and returns the copy's location. The same bytes are only
    /// copied once: when the newest copy already holds them, that copy is returned.
    @discardableResult
    static func preserve(
        _ data: Data,
        of url: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let existing = copies(of: url, fileManager: fileManager)
        if let newest = existing.last, (try? Data(contentsOf: newest)) == data {
            return newest
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent + marker + formatter.string(from: now)
        let ext = url.pathExtension
        var candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = "\(stem)-\(suffix)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            suffix += 1
        }
        // `.withoutOverwriting`: a copy is never written over another file either.
        try data.write(to: candidate, options: [.withoutOverwriting])

        let all = copies(of: url, fileManager: fileManager)
        for old in all.dropLast(keptCopies) where old != candidate {
            try? fileManager.removeItem(at: old)
        }
        return candidate
    }

    /// The copies made of `url`, oldest first.
    static func copies(of url: URL, fileManager: FileManager = .default) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent + marker
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                // Same-second copies carry "-2", "-3": compare the date part, then the counter.
                let left = sortKey(lhs), right = sortKey(rhs)
                return left.date != right.date ? left.date < right.date : left.counter < right.counter
            }
            .map { directory.appendingPathComponent($0) }
    }

    private static func sortKey(_ name: String) -> (date: String, counter: Int) {
        guard let range = name.range(of: marker) else { return (name, 0) }
        let rest = name[range.upperBound...].split(separator: ".").first.map(String.init) ?? ""
        // yyyy-MM-dd-HHmmss is 17 characters; anything after it is the counter.
        let date = String(rest.prefix(17))
        let counter = Int(rest.dropFirst(18)) ?? 1
        return (date, counter)
    }

    /// One line for the log: the coding path and what was wrong, instead of Foundation's
    /// "The data couldn't be read because it isn't in the correct format."
    static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return String(describing: error)
        }
        let context: DecodingError.Context
        switch decodingError {
        case let .dataCorrupted(ctx), let .keyNotFound(_, ctx), let .typeMismatch(_, ctx), let .valueNotFound(_, ctx):
            context = ctx
        @unknown default:
            return String(describing: error)
        }
        let path = codingPathDescription(context.codingPath)
        var line = path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        if let underlying = context.underlyingError {
            line += " (\((underlying as NSError).localizedDescription))"
        }
        return line
    }

    static func codingPathDescription(_ path: [CodingKey]) -> String {
        path.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
