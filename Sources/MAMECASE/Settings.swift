import Foundation
import SwiftUI

/// User-configurable preferences for Mamecase. Backed by UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let mameIniPath = "mameIniPath"
        static let mameExecutablePath = "mameExecutablePath"
        static let romDownloadBaseURL = "romDownloadBaseURL"
    }

    static var defaultMameIniPath: String { AppSettingsDefaults.mameIniPath }
    static var defaultMameExecutablePath: String { AppSettingsDefaults.mameExecutablePath }

    /// Full path to the user's `mame.ini` file. The directory it sits in
    /// is treated as MAME's home dir for resolving relative paths
    /// (`rompath roms` → `<dir>/roms`, `hashpath hash` → `<dir>/hash`, …).
    @Published var mameIniPath: String {
        didSet { UserDefaults.standard.set(mameIniPath, forKey: Keys.mameIniPath) }
    }

    @Published var mameExecutablePath: String {
        didSet { UserDefaults.standard.set(mameExecutablePath, forKey: Keys.mameExecutablePath) }
    }

    @Published var romDownloadBaseURL: String {
        didSet { UserDefaults.standard.set(romDownloadBaseURL, forKey: Keys.romDownloadBaseURL) }
    }

    init() {
        let defaults = UserDefaults.standard
        // Empty string means "use the default" — the TextField will show
        // the default as placeholder text, and the loader falls back
        // accordingly.
        self.mameIniPath = defaults.string(forKey: Keys.mameIniPath) ?? ""
        self.mameExecutablePath = defaults.string(forKey: Keys.mameExecutablePath) ?? ""
        self.romDownloadBaseURL = defaults.string(forKey: Keys.romDownloadBaseURL) ?? ""
    }

    /// Snapshot for passing to non-MainActor code.
    func snapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            mameIniPath: mameIniPath,
            mameExecutablePath: mameExecutablePath,
            romDownloadBaseURL: romDownloadBaseURL
        )
    }
}

/// Default values, kept outside the MainActor-isolated class so they can be
/// referenced from any context (e.g. the loader).
enum AppSettingsDefaults {
    static let mameIniPath = "~/.mame/mame.ini"
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
    let mameIniPath: String
    let mameExecutablePath: String
    let romDownloadBaseURL: String

    var effectiveMameIniPath: String {
        let trimmed = mameIniPath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? AppSettingsDefaults.mameIniPath : trimmed
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

    /// Resolved `mame.ini` URL with `~` expanded.
    var resolvedMameIni: URL {
        let expanded = (effectiveMameIniPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Directory containing the mame.ini file — used as MAME's home for
    /// resolving relative paths in the ini.
    var resolvedMameHome: URL {
        resolvedMameIni.deletingLastPathComponent()
    }
}
