import Foundation

/// Resolves a local file URL for a given (entry, kind) pair.
///
/// The eventual resolution chain will be:
///   1. Loose file in the mame.ini-defined path.
///   2. Archive (zip/7z) at the same path, extracted once into our cache.
///   3. Online fetch (libretro / OpenVGDB), cached locally.
///
/// For now only (1) is implemented; (2) and (3) follow in later phases.
/// The returned URL — when non-nil — is always a real local file that
/// callers can hand to `NSImage(contentsOf:)`.
enum MediaProvider {
    static func url(for entry: Entry, kind: MediaKind, config: MameConfig) -> URL? {
        looseFileURL(for: entry, kind: kind, config: config)
    }

    // MARK: - Phase 1: loose files

    private static let imageExtensions = ["png", "jpg", "jpeg"]

    private static func looseFileURL(for entry: Entry, kind: MediaKind, config: MameConfig) -> URL? {
        let fm = FileManager.default
        let basename = self.basename(for: entry)
        for dir in directories(for: entry, kind: kind, config: config) {
            for ext in imageExtensions {
                let url = dir.appendingPathComponent("\(basename).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
            if kind == .snap {
                // MAME's snap convention also nests per-machine subdirs.
                let subdir = dir.appendingPathComponent(basename, isDirectory: true)
                for fileName in ["0000.png", "snap.png"] {
                    let url = subdir.appendingPathComponent(fileName)
                    if fm.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }

    private static func directories(for entry: Entry, kind: MediaKind, config: MameConfig) -> [URL] {
        switch (kind, entry.kind) {
        case (.snap, _):
            return config.snapPaths
        case (.coverArt, .arcade):
            return config.flyerPaths
        case (.coverArt, .software):
            return config.coverPaths
        }
    }

    /// Per-entry path stem inside a media directory.
    /// - Arcade machines are flat (`pacman.png`).
    /// - Software-list entries are nested by list (`nes/zelda.png`).
    private static func basename(for entry: Entry) -> String {
        switch entry.kind {
        case .arcade: return entry.shortName
        case .software(let system): return "\(system)/\(entry.shortName)"
        }
    }
}
