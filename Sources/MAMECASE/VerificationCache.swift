import Foundation

/// On-disk cache of `mame -verifyroms` results so we don't re-audit ROMs
/// whose underlying file hasn't changed.
///
/// Cache key: `Entry.ID`. Validity is derived from the ROM zip's size +
/// modification time at the time of verification — so a replaced or
/// re-downloaded zip automatically invalidates the prior result.
///
/// `notFound` records are kept valid as long as the file remains absent,
/// which prevents repeatedly re-checking ROMs the user doesn't own.
enum VerificationCache {
    struct Record: Codable {
        let status: RomStatus
        let size: UInt64
        let mtime: TimeInterval
    }

    private static let fileName = "verifications.json"

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Mamecase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> [Entry.ID: Record] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([Entry.ID: Record].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ map: [Entry.ID: Record]) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// Build a fresh record from the current state of the ROM file.
    static func makeRecord(status: RomStatus, for entry: Entry, romPaths: [URL]) -> Record {
        if let url = romFile(for: entry, in: romPaths),
           let meta = fileMetadata(url) {
            return Record(status: status, size: meta.size, mtime: meta.mtime)
        }
        return Record(status: status, size: 0, mtime: 0)
    }

    /// Returns the cached status iff it's still valid:
    ///   - `notFound` records: valid while the file is still absent.
    ///   - all others: file must exist with matching size + mtime.
    static func freshStatus(for entry: Entry,
                            romPaths: [URL],
                            cache: [Entry.ID: Record]) -> RomStatus? {
        guard let record = cache[entry.id] else { return nil }
        let url = romFile(for: entry, in: romPaths)
        if record.status == .notFound {
            return url == nil ? .notFound : nil
        }
        guard let url, let meta = fileMetadata(url) else { return nil }
        if record.size == meta.size && abs(record.mtime - meta.mtime) < 0.001 {
            return record.status
        }
        return nil
    }

    /// Locate the on-disk ROM file for `entry` by walking rompaths.
    static func romFile(for entry: Entry, in romPaths: [URL]) -> URL? {
        let fm = FileManager.default
        let names: [String]
        switch entry.kind {
        case .arcade:
            names = ["\(entry.shortName).zip", "\(entry.shortName).7z"]
        case .software(let system):
            names = [
                "\(system)/\(entry.shortName).zip",
                "\(system)/\(entry.shortName).7z"
            ]
        }
        for dir in romPaths {
            for name in names {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private static func fileMetadata(_ url: URL) -> (size: UInt64, mtime: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let modDate = attrs[.modificationDate] as? Date else { return nil }
        return (size, modDate.timeIntervalSince1970)
    }
}
