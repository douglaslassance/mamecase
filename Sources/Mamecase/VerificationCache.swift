import Foundation

/// On-disk cache of `mame -verifyroms` results so we don't re-audit ROMs
/// whose underlying file hasn't changed.
///
/// Cache key: `Entry.ID`. Validity has two axes:
///   - ROM file size + mtime — a replaced / re-downloaded zip invalidates
///     the prior result.
///   - MAME version banner — MAME bumps its hash database between
///     releases, so a stored "good" verdict from MAME 0.260 isn't
///     trustworthy under MAME 0.275. Any version drift invalidates the
///     entire record.
///
/// `notFound` records are kept valid as long as the file remains absent
/// AND the MAME version still matches, which prevents repeatedly
/// re-checking ROMs the user doesn't own.
enum VerificationCache {
    struct Record: Codable {
        let status: RomStatus
        let size: UInt64
        let mtime: TimeInterval
        /// MAME banner at the moment of verification (first line of
        /// `mame -help`). Optional for back-compat — old records without
        /// a version are treated as stale and re-verified once.
        var mameVersion: String?
        /// Short human summary pulled from the audit output (e.g.
        /// "ROM xxx: BAD CRC"). Surfaced in the tile tooltip. Nil when
        /// the status is .good / .notFound or MAME printed nothing
        /// actionable.
        var details: String?
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
    /// `mameVersion` should be the current `mame -help` banner, written
    /// into the record so a future MAME upgrade invalidates the verdict.
    static func makeRecord(status: RomStatus,
                           details: String?,
                           for entry: Entry,
                           romPaths: [URL],
                           mameVersion: String?) -> Record {
        if let url = romFile(for: entry, in: romPaths),
           let meta = fileMetadata(url) {
            return Record(status: status,
                          size: meta.size,
                          mtime: meta.mtime,
                          mameVersion: mameVersion,
                          details: details)
        }
        return Record(status: status,
                      size: 0,
                      mtime: 0,
                      mameVersion: mameVersion,
                      details: details)
    }

    /// Returns the cached status iff it's still valid:
    ///   - Record's `mameVersion` must match the current MAME banner.
    ///     A nil current version (probe not done yet) refuses to accept
    ///     ANY cache entries — better to defer than to use stale data.
    ///   - `notFound` records: valid while the file is still absent.
    ///   - all others: file must exist with matching size + mtime.
    ///
    /// Note: an earlier version invalidated failing-status records that
    /// lacked captured diagnostic details, hoping a fresh audit would
    /// produce some. In practice many MAME audits never emit parseable
    /// detail lines, so those records kept being re-audited on every
    /// launch — hundreds of background MAME processes that thrashed
    /// `@Published` updates through the gallery and locked up the UI.
    /// A detail-less tooltip is mildly worse than a perpetually-spinning
    /// audit; rely on the manual "Verify ROM" right-click to regenerate
    /// details when you want them.
    static func freshStatus(for entry: Entry,
                            romPaths: [URL],
                            cache: [Entry.ID: Record],
                            mameVersion: String?) -> RomStatus? {
        guard let record = cache[entry.id] else { return nil }
        guard let current = mameVersion,
              let recorded = record.mameVersion,
              recorded == current
        else { return nil }
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
    /// MAME supports several layouts for software-list entries:
    ///   `<system>/<shortname>.zip` / `.7z`  — cartridge sets
    ///   `<system>/<shortname>.chd`           — single-file disc image
    ///   `<system>/<shortname>/`              — multi-file disc / subdir set
    ///   `<system>/<diskname>.chd`            — disc image named per
    ///                                         the `<disk name="…">` from
    ///                                         the software list XML
    ///                                         (No-Intro / Redump dumps)
    /// Arcade is simpler — either `<shortname>.{zip,7z}` or `<shortname>/`.
    static func romFile(for entry: Entry, in romPaths: [URL]) -> URL? {
        let fm = FileManager.default
        var names: [String]
        switch entry.kind {
        case .arcade:
            names = [
                "\(entry.shortName).zip",
                "\(entry.shortName).7z",
                entry.shortName,
            ]
        case .software(let system):
            names = [
                "\(system)/\(entry.shortName).zip",
                "\(system)/\(entry.shortName).7z",
                "\(system)/\(entry.shortName).chd",
                "\(system)/\(entry.shortName)",
            ]
            for disk in entry.diskNames {
                names.append("\(system)/\(disk).chd")
            }
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
