import CryptoKit
import Foundation

/// On-disk cache of parsed software lists. Walking `~/.mame/hash/` and
/// running XMLParser on 600+ XMLs is the biggest single cost in cold
/// startup; the parsed shape rarely changes between launches.
///
/// Invalidation: a signature over each XML's `(filename, size, mtime)`
/// — covers MAME upgrades (new files / new mtimes), manual edits, and
/// third-party hash XMLs the user drops in. The `schemaVersion` field is
/// bumped manually when `CachedEntry` / `CachedSoftwareList` change shape,
/// so an old cache from a previous Mamecase version is rejected even
/// if the XMLs themselves haven't moved.
enum SoftwareListsCache {
    /// Bump whenever the cached shape below changes (e.g. add a new
    /// field to CachedEntry / CachedSoftwareList).
    private static let schemaVersion = 1
    private static let fileName = "software-lists.json"

    private struct Envelope: Codable {
        let schemaVersion: Int
        let signature: String
        let lists: [CachedSoftwareList]
    }

    private struct CachedSoftwareList: Codable {
        let name: String
        let description: String
        let entries: [CachedEntry]
    }

    private struct CachedEntry: Codable {
        let shortName: String
        let displayName: String
        let year: String?
        let publisher: String?
        let diskNames: [String]
    }

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Mamecase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Stable digest of the XML files under `hashPaths`. Sorted before
    /// hashing so directory iteration order doesn't affect the result.
    static func signature(for hashPaths: [URL]) -> String {
        let fm = FileManager.default
        var lines: [String] = []
        for dir in hashPaths {
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files where f.pathExtension.lowercased() == "xml" {
                let attrs = try? f.resourceValues(forKeys: [.fileSizeKey,
                                                            .contentModificationDateKey])
                let size = attrs?.fileSize ?? 0
                let mtime = attrs?.contentModificationDate?.timeIntervalSince1970 ?? 0
                lines.append("\(f.lastPathComponent):\(size):\(mtime)")
            }
        }
        lines.sort()
        let blob = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(blob.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the cached `[SoftwareList]` iff schema + signature match.
    static func load(signature: String) -> [SoftwareList]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let env = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        guard env.schemaVersion == schemaVersion,
              env.signature == signature
        else { return nil }
        return env.lists.map { cached in
            SoftwareList(
                name: cached.name,
                description: cached.description,
                entries: cached.entries.map { e in
                    Entry(kind: .software(system: cached.name),
                          shortName: e.shortName,
                          displayName: e.displayName,
                          year: e.year,
                          publisher: e.publisher,
                          diskNames: e.diskNames)
                }
            )
        }
    }

    /// Persist parsed software lists under the supplied signature.
    static func save(_ lists: [SoftwareList], signature: String) {
        let cached = lists.map { list in
            CachedSoftwareList(
                name: list.name,
                description: list.description,
                entries: list.entries.map { e in
                    CachedEntry(shortName: e.shortName,
                                displayName: e.displayName,
                                year: e.year,
                                publisher: e.publisher,
                                diskNames: e.diskNames)
                }
            )
        }
        let env = Envelope(schemaVersion: schemaVersion,
                           signature: signature,
                           lists: cached)
        guard let data = try? JSONEncoder().encode(env) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
