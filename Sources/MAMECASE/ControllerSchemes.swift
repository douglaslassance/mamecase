import Foundation

/// Persistent map from system identifier to MAME `-ctrlr` profile basename.
///
/// The system identifier matches the sidebar's `SystemNode.id`:
///   - `"arcade"` for MAME machines
///   - a software-list name (e.g. `"nes"`, `"megadriv"`) for software entries
///
/// An empty value means "no override; launch MAME without `-ctrlr`".
enum ControllerSchemes {
    private static let key = "controllerSchemesBySystem"

    static func all() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    static func scheme(for systemID: String) -> String {
        all()[systemID] ?? ""
    }

    static func set(_ scheme: String, for systemID: String) {
        var map = all()
        let trimmed = scheme.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            map.removeValue(forKey: systemID)
        } else {
            map[systemID] = trimmed
        }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Map an `Entry` to the system-ID key we persist under.
    static func systemID(for entry: Entry) -> String {
        switch entry.kind {
        case .arcade: return "arcade"
        case .software(let sys): return sys
        }
    }
}
