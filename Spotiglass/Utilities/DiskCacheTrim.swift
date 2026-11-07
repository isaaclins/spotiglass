import Foundation

/// Keeps a cache directory inside its bounds, using each file's modification date as its age.
///
/// Files older than `maxAge` go first. If the rest still weighs more than `maxBytes`, the least
/// recently modified files go next until the directory is back at three quarters of `maxBytes`,
/// so the next trim isn't due after a single write. Every disk cache in the app trims this way.
enum DiskCacheTrim {
    static func trim(
        directory: URL,
        maxBytes: Int64,
        maxAge: TimeInterval? = nil,
        now: Date = Date(),
        keepingFileNames kept: Set<String> = [],
        fileManager: FileManager = .default
    ) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
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
            if let maxAge, now.timeIntervalSince(date) > maxAge {
                try? fileManager.removeItem(at: url)
                continue
            }
            total += size
            entries.append((url, size, date))
        }

        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > maxBytes * 3 / 4 else { break }
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}
