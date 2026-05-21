import Foundation

/// Persistent set of favorited entry IDs. Stored under
/// `UserDefaults["favorites"]` as a `[String]`. Independent of MAME's own
/// `favorites.ini` (which we'd love to sync with eventually but the
/// 9-fields-per-entry text format is finicky to round-trip).
enum FavoritesStore {
    private static let key = "favorites"

    static func load() -> Set<String> {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else {
            return []
        }
        return Set(raw)
    }

    static func save(_ favorites: Set<String>) {
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: key)
    }
}
