import Foundation

/// Resolves a local file URL for a given (entry, kind) pair.
///
/// Resolution chain:
///   1. Loose file in the mame.ini-defined path.
///   2. Cached file from a prior archive extraction.
///   3. Sibling archive (`<dir>.{zip,7z}` / `<dir>s.{zip,7z}`) bulk-
///      extracted into `~/Library/Caches/Mamecase/media/<kind>/…`.
///
/// Steps 1 and 2 are pure file-existence checks (synchronous). Step 3
/// is asynchronous; callers that want the archive contents must await
/// `extractArchivesIfNeeded(kind:config:)` first.
actor MediaProvider {
    static let shared = MediaProvider()

    private let cacheRoot: URL
    private var extracted: Set<URL> = []
    private var inFlight: [URL: Task<Bool, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheRoot = caches.appendingPathComponent("Mamecase/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    nonisolated func cacheDir(for kind: MediaKind) -> URL {
        cacheRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// Synchronous lookup. Returns a local file URL if we have one, else
    /// nil. Does not extract from archives — for that, await
    /// `extractArchivesIfNeeded(kind:config:)` and call again.
    nonisolated static func url(for entry: Entry, kind: MediaKind, config: MameConfig) -> URL? {
        if let url = looseFileURL(for: entry, kind: kind, config: config) {
            return url
        }
        return cachedFileURL(for: entry, kind: kind)
    }

    /// Extract every sibling archive for `kind` once (idempotent per
    /// archive URL). Returns true if at least one archive was extracted
    /// or already had been; false if none exist.
    @discardableResult
    func extractArchivesIfNeeded(kind: MediaKind, config: MameConfig) async -> Bool {
        let archives = MediaProvider.archiveCandidates(for: kind, config: config)
        guard !archives.isEmpty else { return false }
        let cacheDir = self.cacheDir(for: kind)
        var anyDone = false
        for archive in archives {
            if extracted.contains(archive) { anyDone = true; continue }
            if let task = inFlight[archive] {
                if await task.value { anyDone = true }
                continue
            }
            let task = Task.detached(priority: .utility) {
                do {
                    try ArchiveExtractor.extractAll(archive: archive, into: cacheDir)
                    return true
                } catch {
                    return false
                }
            }
            inFlight[archive] = task
            let ok = await task.value
            inFlight.removeValue(forKey: archive)
            if ok {
                extracted.insert(archive)
                anyDone = true
            }
        }
        return anyDone
    }

    // MARK: - Phase 1: loose files

    private static let imageExtensions = ["png", "jpg", "jpeg"]

    private static func looseFileURL(for entry: Entry, kind: MediaKind, config: MameConfig) -> URL? {
        let fm = FileManager.default
        let basename = basename(for: entry)
        for dir in directories(for: entry, kind: kind, config: config) {
            for ext in imageExtensions {
                let url = dir.appendingPathComponent("\(basename).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
            if kind == .snap {
                let subdir = dir.appendingPathComponent(basename, isDirectory: true)
                for fileName in ["0000.png", "snap.png"] {
                    let url = subdir.appendingPathComponent(fileName)
                    if fm.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }

    // MARK: - Phase 2: cached files from prior archive extraction

    private static func cachedFileURL(for entry: Entry, kind: MediaKind) -> URL? {
        let fm = FileManager.default
        let cacheDir = MediaProvider.shared.cacheDir(for: kind)
        let basename = basename(for: entry)
        for ext in imageExtensions {
            let url = cacheDir.appendingPathComponent("\(basename).\(ext)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Phase 3: archive discovery

    /// Candidate archives that may contain media for `kind`. We look at:
    ///   - any configured path that itself is a `.zip`/`.7z` file
    ///   - sibling archives next to a configured directory:
    ///     `<dir>.{zip,7z}` and `<dir>s.{zip,7z}` (plural variant used by
    ///     some Progetto-SNAPS distributions, e.g. `snaps.7z`)
    ///   - any `.zip`/`.7z` placed *inside* the configured directory
    ///     (e.g. `snap/snap.7z`).
    private static func archiveCandidates(for kind: MediaKind, config: MameConfig) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        let dirs = directories(forKind: kind, config: config)
        let fm = FileManager.default

        func push(_ url: URL) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted, fm.fileExists(atPath: url.path) {
                out.append(url)
            }
        }

        for path in dirs {
            let ext = path.pathExtension.lowercased()
            if ext == "zip" || ext == "7z" {
                push(path)
                continue
            }
            // Sibling at parent level.
            let parent = path.deletingLastPathComponent()
            let name = path.lastPathComponent
            for variant in [name, name + "s"] {
                for archiveExt in ["zip", "7z"] {
                    push(parent.appendingPathComponent("\(variant).\(archiveExt)"))
                }
            }
            // Any archive inside the configured directory.
            if let items = try? fm.contentsOfDirectory(at: path,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) {
                for item in items {
                    let e = item.pathExtension.lowercased()
                    if e == "zip" || e == "7z" { push(item) }
                }
            }
        }
        return out
    }

    // MARK: - Path helpers

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

    /// Same `directories(for:kind:config:)` lookup but without an entry —
    /// used when discovering archives (which is per-kind, not per-entry).
    private static func directories(forKind kind: MediaKind, config: MameConfig) -> [URL] {
        switch kind {
        case .snap: return config.snapPaths
        case .coverArt: return config.flyerPaths + config.coverPaths
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
