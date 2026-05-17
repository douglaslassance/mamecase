import Foundation

/// Persistent map from system identifier to MAME GLSL shader override.
///
/// Keys mirror `ControllerSchemes` (`"arcade"` for arcade entries, the
/// software-list name for software entries). The stored value is the path
/// MAME expects in `-glsl_shader_mame1`, typically `glsl/<basename>` to
/// match how mame.ini references shaders.
enum ShaderSchemes {
    private static let key = "shaderSchemesBySystem"

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

    static func systemID(for entry: Entry) -> String {
        switch entry.kind {
        case .arcade: return "arcade"
        case .software(let sys): return sys
        }
    }
}
