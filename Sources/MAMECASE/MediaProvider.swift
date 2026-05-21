import CryptoKit
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
    private var onlineInFlight: [String: Task<URL?, Never>] = [:]
    private var onlineMisses: Set<String> = []
    /// At most this many `fetchOnline` network calls run concurrently.
    /// Keeps Mamecase polite to libretro-thumbnails / GitHub raw when a
    /// big system view fires hundreds of tile-driven fetches at once.
    private let maxConcurrentFetches = 4
    private var activeFetches = 0
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheRoot = caches.appendingPathComponent("Mamecase/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        MediaProvider.migrateCoverArtToFlyers(in: cacheRoot)
        self.onlineMisses = MediaProvider.loadMisses(root: cacheRoot)
    }

    /// Pre-rename, the cache stored arcade flyer/boxart media under
    /// `media/coverArt/`. Renaming to match MAME's "flyers" terminology
    /// moves the folder to `media/flyers/` and rewrites the misses-file
    /// keys so existing downloads survive the rename. Idempotent.
    private static func migrateCoverArtToFlyers(in root: URL) {
        let fm = FileManager.default
        let oldDir = root.appendingPathComponent("coverArt", isDirectory: true)
        let newDir = root.appendingPathComponent("flyers", isDirectory: true)
        if fm.fileExists(atPath: oldDir.path),
           !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        }
        // Rewrite misses.json keys from `coverArt/...` → `flyers/...`.
        let missesURL = missesFile(root: root)
        if let data = try? Data(contentsOf: missesURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            let migrated = decoded.map { key in
                key.hasPrefix("coverArt/")
                    ? "flyers/" + key.dropFirst("coverArt/".count)
                    : key
            }
            if migrated != decoded,
               let encoded = try? JSONEncoder().encode(migrated) {
                try? encoded.write(to: missesURL, options: .atomic)
            }
        }
    }

    nonisolated func cacheDir(for kind: MediaKind) -> URL {
        cacheRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    nonisolated var cacheRootURL: URL { cacheRoot }

    nonisolated static func basename(for entry: Entry) -> String {
        switch entry.kind {
        case .arcade: return entry.shortName
        case .software(let system): return "\(system)/\(entry.shortName)"
        }
    }

    nonisolated func cacheURL(for entry: Entry, kind: MediaKind) -> URL {
        cacheDir(for: kind).appendingPathComponent("\(MediaProvider.basename(for: entry)).png")
    }

    /// Fetch the entry's media for `kind` online.
    ///   - Arcade: libretro-thumbnails MAME repo (works for both
    ///     `flyers` → flyer/boxart, and `snap` → in-game shot).
    ///   - Software cover art: libretro-thumbnails per-system repo via
    ///     `LibretroThumbnails` (index-on-first-use + fuzzy match).
    ///   - Software snap: no online source today; returns nil.
    /// Caches successful downloads at the same path used by
    /// archive-extracted media, so subsequent synchronous lookups pick it
    /// up automatically.
    func fetchOnline(for entry: Entry, kind: MediaKind) async -> URL? {
        let key = "\(kind.rawValue)/\(MediaProvider.basename(for: entry))"
        let dest = cacheURL(for: entry, kind: kind)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        if onlineMisses.contains(key) { return nil }
        if let task = onlineInFlight[key] { return await task.value }

        let candidates: [URL]
        switch entry.kind {
        case .arcade:
            candidates = libretroCandidates(for: entry, kind: kind)
        case .software:
            guard kind == .flyers,
                  let url = await LibretroThumbnails.shared.coverURL(for: entry)
            else {
                onlineMisses.insert(key)
                saveMisses()
                return nil
            }
            candidates = [url]
        }

        await acquireFetchSlot()
        let session = self.session
        let task = Task.detached(priority: .utility) { () -> URL? in
            for url in candidates {
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200 else { continue }
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try data.write(to: dest, options: .atomic)
                    return dest
                } catch { continue }
            }
            return nil
        }
        onlineInFlight[key] = task
        let result = await task.value
        onlineInFlight.removeValue(forKey: key)
        releaseFetchSlot()
        if result == nil {
            onlineMisses.insert(key)
            saveMisses()
        }
        return result
    }

    /// Remove cached files and online-miss markers for `entry`, forcing
    /// the next resolution attempt to re-run the full chain.
    func invalidate(entry: Entry) {
        let exts = ["png", "jpg", "jpeg"]
        let base = MediaProvider.basename(for: entry)
        var changed = false
        for kind in MediaKind.allCases {
            for ext in exts {
                let url = cacheDir(for: kind).appendingPathComponent("\(base).\(ext)")
                try? FileManager.default.removeItem(at: url)
            }
            if onlineMisses.remove("\(kind.rawValue)/\(base)") != nil { changed = true }
        }
        if changed { saveMisses() }
    }

    private nonisolated func libretroCandidates(for entry: Entry, kind: MediaKind) -> [URL] {
        guard case .arcade = entry.kind else { return [] }
        let bucket: String
        switch kind {
        case .flyers: bucket = "Named_Boxarts"
        case .snap: bucket = "Named_Snaps"
        }
        let display = entry.displayName
        var names: [String] = [display]
        // Libretro often files the parenthetical region/publisher tag
        // separately; some entries are filed without it, so try a trimmed
        // variant as a fallback.
        if let paren = display.range(of: " (", options: .backwards),
           display.hasSuffix(")") {
            let trimmed = String(display[..<paren.lowerBound])
            if !trimmed.isEmpty, trimmed != display { names.append(trimmed) }
        }
        return names.compactMap { name -> URL? in
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return nil
            }
            return URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/MAME/master/\(bucket)/\(encoded).png")
        }
    }

    /// Wipe everything in the media cache. Forces a re-extract / re-fetch
    /// on the next call.
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        extracted.removeAll()
        inFlight.removeAll()
        onlineMisses.removeAll()
        try? FileManager.default.removeItem(at: MediaProvider.missesFile(root: cacheRoot))
    }

    // MARK: - Concurrency cap

    /// Reserve one of `maxConcurrentFetches` outstanding network slots.
    /// Suspends until a slot becomes available; releasers hand the slot
    /// directly to the first waiter so the in-flight count never exceeds
    /// the cap even under contention.
    private func acquireFetchSlot() async {
        if activeFetches < maxConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            fetchWaiters.append(c)
        }
    }

    private func releaseFetchSlot() {
        if !fetchWaiters.isEmpty {
            let next = fetchWaiters.removeFirst()
            next.resume()
        } else {
            activeFetches -= 1
        }
    }

    // MARK: - Persistent miss cache

    private static let missesFileName = "misses.json"

    private static func missesFile(root: URL) -> URL {
        root.appendingPathComponent(missesFileName)
    }

    private static func loadMisses(root: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: missesFile(root: root)),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private func saveMisses() {
        let url = MediaProvider.missesFile(root: cacheRoot)
        if let data = try? JSONEncoder().encode(Array(onlineMisses).sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Recursively sum the size of every file under the media cache.
    /// Slow for large caches; run from a background task.
    nonisolated func currentCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: cacheRoot,
                                             includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
            if vals?.isRegularFile == true, let size = vals?.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
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

    /// Outcome reported back to `Library` so the UI can act on missing
    /// extractor tools.
    struct ExtractionResult {
        var anySucceeded: Bool = false
        var needsSevenZip: Bool = false
        /// Archives that look like Git LFS pointer files (e.g. an `~/.mame`
        /// repo where `git lfs pull` hasn't been run).
        var lfsPointers: [URL] = []
    }

    /// Extract every sibling archive for `kind` once (idempotent per
    /// archive URL). Re-extracts (after wiping the kind's cache) when the
    /// source archive on disk has changed since the last extraction.
    @discardableResult
    func extractArchivesIfNeeded(kind: MediaKind, config: MameConfig) async -> ExtractionResult {
        let archives = MediaProvider.archiveCandidates(for: kind, config: config)
        guard !archives.isEmpty else { return ExtractionResult() }
        let cacheDir = self.cacheDir(for: kind)
        var out = ExtractionResult()

        // Compare each archive's current fingerprint with the cached one.
        // Any mismatch (or absent cached record) → wipe this kind's cache
        // entirely and force re-extract.
        var fingerprints = MediaArchiveCache.load()
        let staleArchives = archives.filter { archive in
            guard let current = ArchiveFingerprint.current(for: archive) else { return true }
            return fingerprints[archive.path].map { !$0.matches(current) } ?? true
        }
        if !staleArchives.isEmpty {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            for archive in archives {
                extracted.remove(archive)
            }
        }
        for archive in archives {
            if extracted.contains(archive) { out.anySucceeded = true; continue }
            if let task = inFlight[archive] {
                if await task.value { out.anySucceeded = true }
                continue
            }
            enum Outcome: Sendable { case success, lfsPointer, otherFailure }
            let task = Task.detached(priority: .utility) { () -> Outcome in
                do {
                    try ArchiveExtractor.extractAll(archive: archive, into: cacheDir)
                    return .success
                } catch ArchiveError.gitLFSPointer {
                    return .lfsPointer
                } catch {
                    return .otherFailure
                }
            }
            let outcome: Outcome
            do {
                let proxy = Task<Bool, Never> { await task.value == .success }
                inFlight[archive] = proxy
                outcome = await task.value
                _ = await proxy.value
                inFlight.removeValue(forKey: archive)
            }
            switch outcome {
            case .success:
                extracted.insert(archive)
                out.anySucceeded = true
                if let fingerprint = ArchiveFingerprint.current(for: archive) {
                    fingerprints[archive.path] = fingerprint
                }
            case .lfsPointer:
                out.lfsPointers.append(archive)
            case .otherFailure:
                if archive.pathExtension.lowercased() == "7z",
                   !ArchiveExtractor.sevenZipAvailable() {
                    out.needsSevenZip = true
                }
            }
        }
        if out.anySucceeded {
            await purgePlaceholders(in: cacheDir)
            MediaArchiveCache.save(fingerprints)
        }
        return out
    }

    /// Many art distributions ship a single "no image" placeholder
    /// duplicated under every missing game's shortname. After extracting,
    /// look for byte-identical duplicates and remove them so missing
    /// entries fall through to the gamepad placeholder Mamecase already
    /// shows.
    ///
    /// Two strategies, in order:
    ///   1. Hash a user-named reference file (`placeholderBasename`,
    ///      default `fh_l3`) and delete every other file with the same
    ///      hash.
    ///   2. Fall back to grouping by file size; any size shared by 50+
    ///      files in the same directory is treated as a placeholder.
    private func purgePlaceholders(in dir: URL) async {
        await Task.detached(priority: .utility) {
            MediaProvider.purgePlaceholdersImpl(in: dir)
        }.value
    }

    private static func purgePlaceholdersImpl(in dir: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir,
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles])
        else { return }

        var files: [(URL, Int)] = []
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard vals?.isRegularFile == true, let size = vals?.fileSize else { continue }
            let ext = url.pathExtension.lowercased()
            guard ext == "png" || ext == "jpg" || ext == "jpeg" else { continue }
            files.append((url, size))
        }
        guard !files.isEmpty else { return }

        let placeholderBasename = UserDefaults.standard.string(forKey: "placeholderBasename") ?? "fh_l3"

        // Strategy 1: hash a named reference file, delete matches.
        if let reference = files.first(where: { $0.0.deletingPathExtension().lastPathComponent == placeholderBasename }),
           let refHash = sha256(of: reference.0) {
            var removed = 0
            for (url, _) in files {
                guard let h = sha256(of: url), h == refHash else { continue }
                try? fm.removeItem(at: url)
                removed += 1
            }
            if removed > 0 { return }
        }

        // Strategy 2: group by size, drop the dominant bucket (≥ 50).
        var bySize: [Int: [URL]] = [:]
        for (url, size) in files { bySize[size, default: []].append(url) }
        for (_, urls) in bySize where urls.count >= 50 {
            for url in urls { try? fm.removeItem(at: url) }
        }
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        case (.flyers, .arcade):
            return config.flyerPaths
        case (.flyers, .software):
            return config.coverPaths
        }
    }

    /// Same `directories(for:kind:config:)` lookup but without an entry —
    /// used when discovering archives (which is per-kind, not per-entry).
    private static func directories(forKind kind: MediaKind, config: MameConfig) -> [URL] {
        switch kind {
        case .snap: return config.snapPaths
        case .flyers: return config.flyerPaths + config.coverPaths
        }
    }

}
