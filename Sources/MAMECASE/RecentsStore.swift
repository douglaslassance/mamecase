import Foundation

/// Persistent list of recently-launched entry IDs, most recent first.
/// Stored as JSON in Application Support so it survives cache clears.
enum RecentsStore {
    static let maxEntries = 50

    private static let fileName = "recents.json"

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Mamecase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    static func save(_ ids: [String]) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Push `id` to the front, deduping and truncating to `maxEntries`.
    static func bumped(_ id: String, current: [String]) -> [String] {
        var out = current.filter { $0 != id }
        out.insert(id, at: 0)
        if out.count > maxEntries { out = Array(out.prefix(maxEntries)) }
        return out
    }
}
