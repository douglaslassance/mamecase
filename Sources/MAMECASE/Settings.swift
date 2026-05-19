import Foundation
import SwiftUI

/// User-configurable preferences for Mamecase. Backed by UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let mameHomePath = "mameHomePath"
        static let mameExecutablePath = "mameExecutablePath"
        static let additionalRomPaths = "additionalRomPaths"
        static let romDownloadBaseURL = "romDownloadBaseURL"
    }

    static var defaultMameHomePath: String { AppSettingsDefaults.mameHomePath }
    static var defaultMameExecutablePath: String { AppSettingsDefaults.mameExecutablePath }

    @Published var mameHomePath: String {
        didSet { UserDefaults.standard.set(mameHomePath, forKey: Keys.mameHomePath) }
    }

    @Published var mameExecutablePath: String {
        didSet { UserDefaults.standard.set(mameExecutablePath, forKey: Keys.mameExecutablePath) }
    }

    @Published var additionalRomPaths: [String] {
        didSet { UserDefaults.standard.set(additionalRomPaths, forKey: Keys.additionalRomPaths) }
    }

    @Published var romDownloadBaseURL: String {
        didSet { UserDefaults.standard.set(romDownloadBaseURL, forKey: Keys.romDownloadBaseURL) }
    }

    init() {
        let defaults = UserDefaults.standard
        // Empty string means "use the default" — the TextField will show the
        // default as placeholder text, and the loader falls back accordingly.
        self.mameHomePath = defaults.string(forKey: Keys.mameHomePath) ?? ""
        self.mameExecutablePath = defaults.string(forKey: Keys.mameExecutablePath) ?? ""
        self.additionalRomPaths = (defaults.array(forKey: Keys.additionalRomPaths) as? [String]) ?? []
        self.romDownloadBaseURL = defaults.string(forKey: Keys.romDownloadBaseURL) ?? ""
    }

    /// Resolved ~/.mame URL from `mameHomePath`. Expands `~`.
    var resolvedMameHome: URL {
        let expanded = (mameHomePath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Snapshot for passing to non-MainActor code.
    func snapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            mameHomePath: mameHomePath,
            mameExecutablePath: mameExecutablePath,
            additionalRomPaths: additionalRomPaths,
            romDownloadBaseURL: romDownloadBaseURL
        )
    }
}

/// Default values, kept outside the MainActor-isolated class so they can be
/// referenced from any context (e.g. the loader).
enum AppSettingsDefaults {
    static let mameHomePath = "~/.mame"
    static let mameExecutablePath = "mame"
    // The archive.org `mame-merged` collection matches the
    // `<shortname>.zip` convention this code expects:
    //   https://archive.org/download/mame-merged/
    static let romDownloadBaseURL = ""
}

/// Immutable value-type copy of Settings for use off the main actor.
///
/// Stored values may be empty strings, meaning "use the default". The
/// `effective*` properties apply that fallback so callers don't have to.
struct SettingsSnapshot {
    let mameHomePath: String
    let mameExecutablePath: String
    let additionalRomPaths: [String]
    let romDownloadBaseURL: String

    var effectiveMameHomePath: String {
        let trimmed = mameHomePath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? AppSettingsDefaults.mameHomePath : trimmed
    }

    var effectiveMameExecutablePath: String {
        let trimmed = mameExecutablePath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? AppSettingsDefaults.mameExecutablePath : trimmed
    }

    /// Trimmed user-supplied URL, or empty when not set. There is no
    /// fallback — an empty URL means "ROM downloads disabled".
    var effectiveRomDownloadBaseURL: String {
        romDownloadBaseURL.trimmingCharacters(in: .whitespaces)
    }

    var resolvedMameHome: URL {
        let expanded = (effectiveMameHomePath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
