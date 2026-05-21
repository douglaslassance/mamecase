import Foundation

/// Per-archive fingerprint persisted next to the media cache. Used to
/// invalidate the extracted cache when the source archive on disk
/// changes (e.g. you swapped your `flyers.7z` for a newer SNAPS pack).
///
/// Fingerprint is `(size, mtime)` — cheap to compute, reliable for
/// detecting any normal file replacement (cat-built archives, downloaded
/// files, swapped LFS pointers). A SHA upgrade later is trivial; the
/// schema already includes a `sha` field that's just empty for now.
struct ArchiveFingerprint: Codable, Equatable {
    let size: UInt64
    let mtime: TimeInterval
    var sha: String?

    static func current(for url: URL) -> ArchiveFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let modDate = attrs[.modificationDate] as? Date else { return nil }
        return ArchiveFingerprint(size: size, mtime: modDate.timeIntervalSince1970, sha: nil)
    }

    func matches(_ other: ArchiveFingerprint) -> Bool {
        size == other.size && abs(mtime - other.mtime) < 0.001
    }
}

enum MediaArchiveCache {
    private static let fileName = "media-archives.json"

    private static var url: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Mamecase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> [String: ArchiveFingerprint] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ArchiveFingerprint].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ records: [String: ArchiveFingerprint]) {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
