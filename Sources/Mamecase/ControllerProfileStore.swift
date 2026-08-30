import Foundation

/// Remembers which MAME `-ctrlr` profile the user picked for a given
/// pairing of system and connected controllers.
///
/// The key holds the *set* of connected pads rather than a single one.
/// With one pad plugged in there is nothing to disambiguate. With two,
/// the user teaches once which profile wins and it sticks, instead of
/// the app guessing from plug order. "Nothing connected" is just the
/// empty set, so reverting to a keyboard profile when everything is
/// unplugged needs no special case.
///
/// One `-ctrlr` file can only describe a single pad type across all
/// four players, so a two-pad entry chooses which seat gets the correct
/// layout. It cannot make both correct. Generating a merged profile
/// with `<mapdevice>` is what would fix that, and is deliberately not
/// part of this.
enum ControllerProfileStore {
    private static let defaultsKey = "controllerProfiles"
    /// Pre-existing single global profile. Used as the fallback for any
    /// pairing the user has not taught yet, so behaviour is unchanged
    /// until they start teaching.
    private static let legacyKey = "controllerScheme"

    /// Canonical key. Devices are sorted by identity so plug order never
    /// produces two entries for the same physical setup.
    static func key(system: String, devices: [GameControllerDevice]) -> String {
        let ids = devices.map(\.id).sorted().joined(separator: "+")
        return "\(system)/\(ids.isEmpty ? "none" : ids)"
    }

    /// The profile taught for this pairing, or the legacy global value
    /// if there isn't one yet. Empty string means MAME's own defaults.
    static func profile(system: String, devices: [GameControllerDevice]) -> String {
        if let taught = table()[key(system: system, devices: devices)] { return taught }
        return UserDefaults.standard.string(forKey: legacyKey) ?? ""
    }

    /// Empty `profile` ("Default") is stored rather than removed. It is a
    /// real choice for this pairing, and storing it stops the picker
    /// springing back to the legacy fallback.
    static func setProfile(_ profile: String, system: String, devices: [GameControllerDevice]) {
        var next = table()
        next[key(system: system, devices: devices)] = profile
        UserDefaults.standard.set(next, forKey: defaultsKey)
    }

    /// Resolve at launch time from the entry itself, not from the
    /// sidebar selection, so cross-system nodes (All, Recent, playlists)
    /// and multi-entry launches still get the right profile per game.
    @MainActor
    static func profile(for entry: Entry) -> String {
        profile(system: entry.kind.systemToken, devices: ControllerDetector.shared.connected)
    }

    private static func table() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}

extension EntryKind {
    /// Stable string identifying the system an entry belongs to. Matches
    /// `SoftwareList.name` (the MAME machine name, e.g. `snes`).
    var systemToken: String {
        switch self {
        case .arcade: return "arcade"
        case .software(let system): return system
        }
    }
}

extension SystemNode.Kind {
    /// `nil` for cross-system nodes (All, Recent, playlists). Those pool
    /// entries from several systems, so there is no single profile to
    /// show or edit and the picker hides itself.
    var systemToken: String? {
        switch self {
        case .arcade: return "arcade"
        case .software(let listName): return listName
        case .cross: return nil
        }
    }
}
