import AppKit
import CryptoKit
import Foundation

/// Loads Spotify CDN artwork with memory + disk layers and a URLSession `URLCache` for HTTP caching.
actor ArtworkImageStore {
    static let shared = ArtworkImageStore()

    private let memoryKeys: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 280
        return c
    }()

    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let diskDirectory: URL
    private let urlSession: URLSession
    private let responseURLCache: URLCache
    private let maxDiskBytes: Int64 = 50 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskDirectory = base
            .appendingPathComponent(AppMetadata.displayName, isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)

        let config = URLSessionConfiguration.default
        let urlCacheDir = base.appendingPathComponent(AppMetadata.displayName, isDirectory: true)
            .appendingPathComponent("ArtworkURLCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: urlCacheDir, withIntermediateDirectories: true)
        let urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 96 * 1024 * 1024,
            diskPath: urlCacheDir.path
        )
        responseURLCache = urlCache
        config.urlCache = urlCache
        urlSession = URLSession(configuration: config)

        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let cached = memoryKeys.object(forKey: key as NSString) {
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task<NSImage?, Never> {
            await self.loadThroughDiskAndNetwork(url: url, key: key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    nonisolated static func cacheFileURL(for url: URL, diskDirectory: URL) -> URL {
        let name = Self.sha256Hex(url.absoluteString) + ".img"
        return diskDirectory.appendingPathComponent(name)
    }

    /// Best-effort synchronous read for views that must render immediately (for
    /// example drag previews). Returns `nil` when artwork has not been cached yet.
    nonisolated static func cachedImageIfAvailable(for url: URL) -> NSImage? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let diskDirectory = base
            .appendingPathComponent(AppMetadata.displayName, isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        let fileURL = cacheFileURL(for: url, diskDirectory: diskDirectory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }

    private func loadThroughDiskAndNetwork(url: URL, key: String) async -> NSImage? {
        let fileURL = Self.cacheFileURL(for: url, diskDirectory: diskDirectory)
        if let data = try? Data(contentsOf: fileURL),
           let image = NSImage(data: data) {
            memoryKeys.setObject(image, forKey: key as NSString)
            return image
        }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                return nil
            }
            guard let image = NSImage(data: data) else {
                return nil
            }
            memoryKeys.setObject(image, forKey: key as NSString)
            try? data.write(to: fileURL, options: [.atomic])
            await trimDiskCacheIfNeeded()
            return image
        } catch {
            return nil
        }
    }

    private func trimDiskCacheIfNeeded() async {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        var total: Int64 = 0
        var entries: [(url: URL, date: Date)] = []
        for url in files {
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = vals.fileSize.map(Int64.init) else {
                continue
            }
            total += size
            entries.append((url, vals.contentModificationDate ?? .distantPast))
        }
        guard total > maxDiskBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > maxDiskBytes * 3 / 4 else { break }
            if let s = try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                try? fm.removeItem(at: entry.url)
                total -= Int64(s)
            }
        }
    }

    private nonisolated static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Clears memory and on-disk artwork (call on disconnect).
    func clearAllCachedImages() {
        memoryKeys.removeAllObjects()
        inFlight.removeAll()
        responseURLCache.removeAllCachedResponses()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }
}
