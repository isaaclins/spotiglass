import Foundation

/// Keeps a cache directory inside its bounds, using each file's modification date as its age.
///
/// Files older than `maxAge` go first. If the rest still weighs more than `maxBytes`, the least
/// recently modified files go next until the directory is back at three quarters of `maxBytes`,
/// so the next trim isn't due after a single write. Every disk cache in the app trims this way.
enum DiskCacheTrim {
    /// Trims run one at a time. Two trims of one directory listed together would each delete
    /// down from the same total, and the second would carry on into the newest files.
    private static let lock = NSLock()

    /// `willDelete` runs right before each file is checked one last time and deleted
    /// (`SpotiglassTests` only, to write or trim in that window).
    static func trim(
        directory: URL,
        maxBytes: Int64,
        maxAge: TimeInterval? = nil,
        now: Date = Date(),
        keepingFileNames kept: Set<String> = [],
        fileManager: FileManager = .default,
        willDelete: (URL) -> Void = { _ in }
    ) {
        lock.lock()
        defer { lock.unlock() }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        /// Deletes the file unless it was written or used since it was listed.
        func deleteIfUnchanged(_ url: URL, listedDate: Date) -> Bool {
            willDelete(url)
            guard let current = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  current <= listedDate else {
                return false
            }
            return (try? fileManager.removeItem(at: url)) != nil
        }

        var total: Int64 = 0
        var entries: [(url: URL, size: Int64, date: Date)] = []
        for url in files where !kept.contains(url.lastPathComponent) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize.map(Int64.init) else {
                continue
            }
            let date = values.contentModificationDate ?? .distantPast
            if let maxAge, now.timeIntervalSince(date) > maxAge, deleteIfUnchanged(url, listedDate: date) {
                continue
            }
            total += size
            entries.append((url, size, date))
        }

        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > maxBytes * 3 / 4 else { break }
            if deleteIfUnchanged(entry.url, listedDate: entry.date) {
                total -= entry.size
            }
        }
    }
}
