import Foundation

/// On-disk cache for the arcade entry list. Parsing `mame -listfull` takes
/// several minutes; we persist the result so the gallery is usable
/// immediately on subsequent launches and refresh in the background.
enum ArcadeCache {
    private struct Record: Codable {
        let shortName: String
        let displayName: String
    }

    private static let fileName = "arcade-index.json"

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("MAMECASE", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> [Entry]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let records = try? JSONDecoder().decode([Record].self, from: data),
              !records.isEmpty else { return nil }
        return records.map {
            Entry(kind: .arcade,
                  shortName: $0.shortName,
                  displayName: $0.displayName,
                  year: nil,
                  publisher: nil)
        }
    }

    static func save(_ entries: [Entry]) {
        let records = entries.compactMap { entry -> Record? in
            guard case .arcade = entry.kind else { return nil }
            return Record(shortName: entry.shortName, displayName: entry.displayName)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
