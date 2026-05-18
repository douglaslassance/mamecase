import Foundation

/// Persistent list of user-created playlists. Stored as JSON in
/// Application Support so it survives cache clears and reinstalls.
enum PlaylistsStore {
    private static let fileName = "playlists.json"

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Mamecase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> [Playlist] {
        guard let data = try? Data(contentsOf: fileURL),
              let lists = try? JSONDecoder().decode([Playlist].self, from: data) else { return [] }
        return lists
    }

    static func save(_ playlists: [Playlist]) {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
