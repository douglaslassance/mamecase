import Combine
import Foundation
import SwiftUI

private extension String {
    /// Capitalize the first letter of each whitespace-separated word, leaving
    /// the rest of each word alone. Preserves all-caps acronyms like "NES"
    /// (unlike `.capitalized`, which would lowercase the trailing letters).
    var titleCased: String {
        self.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

@MainActor
final class Library: ObservableObject {
    @Published var config: MameConfig?
    @Published var softwareLists: [SoftwareList] = []
    @Published var arcadeEntries: [Entry] = []
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var arcadeIndexing = false
    @Published var arcadeStatus: String?
    @Published var presence: PresenceIndex = .empty
    @Published var controllerSchemes: [String] = []
    @Published var shaderSchemes: [String] = []
    @Published var verifications: [Entry.ID: RomStatus] = [:]
    @Published var verifyingIDs: Set<Entry.ID> = []
    @Published var favorites: Set<Entry.ID> = FavoritesStore.load()
    /// Entry IDs in launch order, most recent first. Populated by
    /// `launch(_:)`; persisted in Phase 4.
    @Published var recentlyLaunched: [Entry.ID] = RecentsStore.load()
    /// User-curated lists of entries. Populated/persisted in Phase 5.
    @Published var playlists: [Playlist] = []
    @Published var isVerifyingAll: Bool = false
    /// In-memory mirror of `verifications.json` so we can decide cache hits
    /// without touching disk on every entry.
    private var verificationCache: [Entry.ID: VerificationCache.Record] = [:]
    @Published var downloadingIDs: Set<Entry.ID> = []
    @Published var downloadStatus: String?
    @Published var mameMissing: Bool = false
    @Published var brewAvailable: Bool = false
    @Published var installingMame: Bool = false
    @Published var sevenZipMissing: Bool = false
    @Published var installingSevenZip: Bool = false
    /// Set of media kinds we've already kicked off an archive-extraction
    /// pass for; suppresses duplicate work across tiles.
    @Published private(set) var extractingMedia: Set<MediaKind> = []
    /// Bumped after each archive extraction so tile views re-query the
    /// media cache. (The cached files appearing on disk doesn't trigger
    /// SwiftUI re-renders by itself.)
    @Published private(set) var mediaGeneration: Int = 0

    private var settingsCancellables: Set<AnyCancellable> = []

    /// Returns the visible systems, optionally filtered to those with at least one owned entry.
    func systems(hideMissing: Bool) -> [SystemNode] {
        var nodes: [SystemNode] = []
        if !arcadeEntries.isEmpty {
            let count = hideMissing ? arcadeEntries.filter(\.owned).count : arcadeEntries.count
            if count > 0 {
                nodes.append(SystemNode(id: "arcade",
                                        displayName: "Arcade",
                                        count: count,
                                        kind: .arcade))
            }
        }
        let sorted = softwareLists.sorted {
            $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending
        }
        for list in sorted {
            let total = list.entries.count
            let count = hideMissing ? list.entries.filter(\.owned).count : total
            guard count > 0 else { continue }
            let raw = list.description.isEmpty ? list.name : list.description
            nodes.append(SystemNode(id: list.name,
                                    displayName: raw.titleCased,
                                    count: count,
                                    kind: .software(listName: list.name)))
        }
        return nodes
    }

    /// Human-readable label for a software-list short name, e.g.
    /// `"nes"` → `"Nintendo Entertainment System Cartridges"`.
    func softwareListDisplayName(for shortName: String) -> String? {
        softwareLists.first { $0.name == shortName }?.description
    }

    func entries(for system: SystemNode, hideMissing: Bool) -> [Entry] {
        let all: [Entry]
        switch system.kind {
        case .arcade:
            all = arcadeEntries
        case .software(let name):
            all = softwareLists.first(where: { $0.name == name })?.entries ?? []
        case .cross(let scope):
            switch scope {
            case .all:
                var merged: [Entry] = arcadeEntries
                for list in softwareLists { merged.append(contentsOf: list.entries) }
                all = merged
            case .recent:
                let order = recentlyLaunched
                let lookup = Dictionary(uniqueKeysWithValues:
                    (arcadeEntries.map { ($0.id, $0) }
                     + softwareLists.flatMap { $0.entries }.map { ($0.id, $0) }))
                all = order.compactMap { lookup[$0] }
            case .playlist(let id):
                let ids = playlists.first(where: { $0.id == id })?.entryIDs ?? []
                let lookup = Dictionary(uniqueKeysWithValues:
                    (arcadeEntries.map { ($0.id, $0) }
                     + softwareLists.flatMap { $0.entries }.map { ($0.id, $0) }))
                all = ids.compactMap { lookup[$0] }
            }
        }
        return hideMissing ? all.filter(\.owned) : all
    }

    func load(settings: AppSettings) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let snapshot = settings.snapshot()
        do {
            let cfg = try MameConfigLoader.load(settings: snapshot)
            self.config = cfg
            self.mameMissing = false
            rebuildControllerSchemes()
            rebuildShaderSchemes()

            // Hydrate verification cache so tile badges appear immediately
            // for ROMs we verified in a previous session.
            self.verificationCache = VerificationCache.load()
            for (id, record) in verificationCache {
                self.verifications[id] = record.status
            }

            // Hydrate arcade entries from disk cache so the gallery is usable
            // immediately. The fresh `mame -listfull` re-index runs in the
            // background below.
            if let cached = ArcadeCache.load() {
                self.arcadeEntries = cached
            }

            // Kick off archive extraction for media packs (snap.7z,
            // flyers.zip, etc.). No-op if the user has only loose files.
            requestMediaExtraction(for: .snap)
            requestMediaExtraction(for: .coverArt)

            await loadSoftwareLists(cfg: cfg)
            rebuildPresence()
            tagSoftwareOwnership()
            tagArcadeOwnership()

            // Kick off the slow refresh without blocking startup.
            Task { [weak self] in
                await self?.indexArcade()
            }
        } catch MameConfigError.executableNotFound {
            self.mameMissing = true
            self.brewAvailable = BrewInstaller.brewExecutable() != nil
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    /// Run `brew install mame` and reload the library on success.
    func installMameViaBrew(settings: AppSettings) async {
        guard !installingMame, brewAvailable else { return }
        installingMame = true
        arcadeStatus = "brew install mame…"
        let code = await BrewInstaller.installMame()
        arcadeStatus = nil
        installingMame = false
        if code == 0 {
            await load(settings: settings)
        } else {
            loadError = "Homebrew install failed (exit code \(code))."
        }
    }

    private func rebuildControllerSchemes() {
        guard let cfg = config else { return }
        let fm = FileManager.default
        var found: Set<String> = []
        for dir in cfg.ctrlrPaths {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension.lowercased() == "cfg" {
                found.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        self.controllerSchemes = found.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    /// Scan the shader directory for GLSL shaders. Each `.vsh` file is the
    /// entry point of a shader; we return its path relative to the mame
    /// home (e.g. `glsl/glsl_plain`) so it matches the convention used in
    /// `mame.ini`.
    private func rebuildShaderSchemes() {
        guard let cfg = config else { return }
        let fm = FileManager.default
        var found: Set<String> = []
        for dir in cfg.shaderPaths {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension.lowercased() == "vsh" {
                let basename = file.deletingPathExtension().lastPathComponent
                let dirName = dir.lastPathComponent
                found.insert("\(dirName)/\(basename)")
            }
        }
        self.shaderSchemes = found.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    /// Reload everything after settings that affect the mame.ini location or
    /// executable changed. Re-parses software lists.
    func reload(settings: AppSettings) async {
        self.config = nil
        self.softwareLists = []
        self.arcadeEntries = []
        self.presence = .empty
        await load(settings: settings)
    }

    /// Light refresh after only ROM paths changed: reload config, rebuild the
    /// presence index, and retag ownership. Does NOT re-parse software list
    /// XMLs (the expensive part of a full reload).
    func refreshRomPaths(settings: AppSettings) {
        let snapshot = settings.snapshot()
        do {
            let cfg = try MameConfigLoader.load(settings: snapshot)
            self.config = cfg
            rebuildControllerSchemes()
            rebuildShaderSchemes()
            rebuildPresence()
            tagSoftwareOwnership()
            tagArcadeOwnership()
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    /// Subscribe to Settings changes so the library reacts automatically.
    /// Debounced so typing in a text field doesn't fire work on every keystroke.
    func observe(settings: AppSettings) {
        settingsCancellables.removeAll()

        // ROM-paths-only changes: cheap refresh (no XML reparse).
        settings.$additionalRomPaths
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshRomPaths(settings: settings)
            }
            .store(in: &settingsCancellables)

        // Home/executable changes: full reload.
        let home = settings.$mameHomePath.dropFirst().removeDuplicates().map { _ in () }
        let exe = settings.$mameExecutablePath.dropFirst().removeDuplicates().map { _ in () }
        Publishers.Merge(home, exe)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.reload(settings: settings)
                }
            }
            .store(in: &settingsCancellables)
    }

    private func loadSoftwareLists(cfg: MameConfig) async {
        let hashPaths = cfg.hashPaths
        let lists: [SoftwareList] = await Task.detached(priority: .userInitiated) {
            var collected: [SoftwareList] = []
            let fm = FileManager.default
            for hashDir in hashPaths {
                guard let files = try? fm.contentsOfDirectory(at: hashDir,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
                for file in files where file.pathExtension.lowercased() == "xml" {
                    if let list = SoftwareListParser.parse(url: file) {
                        collected.append(list)
                    }
                }
            }
            return collected
        }.value
        self.softwareLists = lists
    }

    private func rebuildPresence() {
        guard let cfg = config else { return }
        let known = Set(softwareLists.map(\.name))
        self.presence = PresenceIndex.build(romPaths: cfg.romPaths, knownSoftwareSystems: known)
    }

    private func tagSoftwareOwnership() {
        softwareLists = softwareLists.map { list in
            let owned = presence.softwareBySystem[list.name] ?? []
            let tagged = list.entries.map { entry -> Entry in
                var e = entry
                e.owned = owned.contains(entry.shortName)
                return e
            }
            return SoftwareList(name: list.name, description: list.description, entries: tagged)
        }
    }

    private func tagArcadeOwnership() {
        arcadeEntries = arcadeEntries.map { entry in
            var e = entry
            e.owned = presence.arcade.contains(entry.shortName)
            return e
        }
    }

    func indexArcade() async {
        guard let cfg = config, !arcadeIndexing else { return }
        arcadeIndexing = true
        arcadeStatus = "Running mame -listxml…"
        defer {
            arcadeIndexing = false
            arcadeStatus = nil
        }
        do {
            let all = try await ArcadeIndex.listAll(executable: cfg.executable)
            arcadeStatus = "Matching against ROM folder…"
            self.arcadeEntries = all
            tagArcadeOwnership()
            ArcadeCache.save(all)
        } catch {
            self.loadError = "Arcade index failed: \(error.localizedDescription)"
        }
    }

    /// Returns a local file URL for the given media kind, or nil if nothing
    /// is available. Delegates to `MediaProvider`.
    func mediaURL(for entry: Entry, kind: MediaKind) -> URL? {
        guard let cfg = config else { return nil }
        return MediaProvider.url(for: entry, kind: kind, config: cfg)
    }

    /// Look up the history/dat text for an entry. First call parses the
    /// XML in the background; subsequent calls are fast dictionary hits.
    func historyText(for entry: Entry) async -> String? {
        guard let cfg = config else { return nil }
        return await HistoryProvider.shared.text(for: entry, historyPaths: cfg.historyPaths)
    }

    /// Try to fetch this entry's media from an online source. No-op when
    /// the user has disabled online fetching (Settings → Media → Sources).
    @discardableResult
    func fetchOnlineMedia(for entry: Entry, kind: MediaKind) async -> URL? {
        await MediaProvider.shared.fetchOnline(for: entry, kind: kind)
    }

    /// Explicit user-driven online fetch for a batch of entries — used by
    /// the "Download Media" context-menu action, which is the only way to
    /// populate art for ROMs the user doesn't own. Ignores any auto-fetch
    /// gates; the concurrency cap in `MediaProvider` keeps it polite.
    func downloadMedia(ids: Set<Entry.ID>, in system: SystemNode) async {
        let targets = entries(for: system, hideMissing: false).filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        arcadeStatus = "Downloading media…"
        defer {
            arcadeStatus = nil
            mediaGeneration &+= 1
        }
        var done = 0
        for entry in targets {
            for kind in MediaKind.allCases {
                _ = await MediaProvider.shared.fetchOnline(for: entry, kind: kind)
            }
            done += 1
            if done % 5 == 0 || done == targets.count {
                arcadeStatus = "Downloading media… \(done)/\(targets.count)"
            }
        }
    }

    // MARK: - Favorites

    func toggleFavorite(_ entry: Entry) {
        if favorites.contains(entry.id) {
            favorites.remove(entry.id)
        } else {
            favorites.insert(entry.id)
        }
        FavoritesStore.save(favorites)
    }

    /// Set favorite state for a batch of entries (used when right-click
    /// fires on a multi-selection).
    func setFavorite(_ favorite: Bool, ids: Set<Entry.ID>) {
        if favorite {
            favorites.formUnion(ids)
        } else {
            favorites.subtract(ids)
        }
        FavoritesStore.save(favorites)
    }

    /// Clear cached media for the selected entries, then re-run the
    /// resolution chain (loose → archive → online) on the next tile
    /// render. Triggered from the "Regenerate Media" context action.
    func regenerateMedia(ids: Set<Entry.ID>, in system: SystemNode) async {
        let targets = entries(for: system, hideMissing: false).filter { ids.contains($0.id) }
        for entry in targets {
            await MediaProvider.shared.invalidate(entry: entry)
        }
        // Bump the generation token so EntryTile `.task` IDs change and
        // the tiles re-run their media resolution.
        mediaGeneration &+= 1
    }

    /// Kick off a one-time bulk extraction for `kind` if archives exist on
    /// disk. Cheap to call from many tiles; the actor inside MediaProvider
    /// deduplicates work per archive.
    func requestMediaExtraction(for kind: MediaKind) {
        guard let cfg = config else { return }
        if extractingMedia.contains(kind) { return }
        extractingMedia.insert(kind)
        arcadeStatus = "Extracting \(kind.label) archive…"
        Task { [weak self] in
            let result = await MediaProvider.shared.extractArchivesIfNeeded(kind: kind, config: cfg)
            await MainActor.run {
                guard let self else { return }
                self.extractingMedia.remove(kind)
                if self.extractingMedia.isEmpty { self.arcadeStatus = nil }
                if result.anySucceeded { self.mediaGeneration &+= 1 }
                if result.needsSevenZip {
                    self.sevenZipMissing = true
                }
                if let pointer = result.lfsPointers.first {
                    self.loadError = "Looks like \(pointer.lastPathComponent) is a Git LFS pointer. Run `git lfs pull` in \(pointer.deletingLastPathComponent().path) and re-launch."
                }
            }
        }
    }

    /// Run `brew install sevenzip` and re-attempt media extraction on success.
    func installSevenZipViaBrew() async {
        guard !installingSevenZip, brewAvailable else { return }
        installingSevenZip = true
        arcadeStatus = "brew install sevenzip…"
        let code = await BrewInstaller.install(package: "sevenzip")
        arcadeStatus = nil
        installingSevenZip = false
        if code == 0 {
            sevenZipMissing = false
            // Retry whichever media kinds were waiting.
            requestMediaExtraction(for: .snap)
            requestMediaExtraction(for: .coverArt)
        } else {
            loadError = "Homebrew install failed (exit code \(code))."
        }
    }

    func launch(_ entry: Entry) {
        guard let cfg = config else { return }
        let scheme = UserDefaults.standard.string(forKey: "controllerScheme") ?? ""
        let shader = UserDefaults.standard.string(forKey: "shaderScheme") ?? ""
        do {
            try MameLauncher.launch(executable: cfg.executable,
                                    args: MameLauncher.arguments(for: entry,
                                                                 romPaths: cfg.romPaths,
                                                                 controllerScheme: scheme,
                                                                 shader: shader),
                                    workingDirectory: cfg.homePath)
            recentlyLaunched = RecentsStore.bumped(entry.id, current: recentlyLaunched)
            RecentsStore.save(recentlyLaunched)
        } catch {
            self.loadError = "Launch failed: \(error.localizedDescription)"
        }
    }

    func launch(ids: Set<Entry.ID>, in system: SystemNode) {
        let all = entries(for: system, hideMissing: false)
        for entry in all where ids.contains(entry.id) {
            launch(entry)
        }
    }

    // MARK: - ROM verification

    /// Run MAME's audit for one entry and record the result. Always runs
    /// MAME regardless of cache state — this is the "force re-check" path
    /// invoked from the per-entry context menu.
    func verify(_ entry: Entry) async {
        guard let cfg = config else { return }
        verifyingIDs.insert(entry.id)
        defer { verifyingIDs.remove(entry.id) }
        let status = await RomVerifier.verify(entry: entry,
                                              executable: cfg.executable,
                                              romPaths: cfg.romPaths)
        verifications[entry.id] = status
        verificationCache[entry.id] = VerificationCache.makeRecord(status: status,
                                                                   for: entry,
                                                                   romPaths: cfg.romPaths)
        VerificationCache.save(verificationCache)
    }

    /// Verify every selected entry sequentially. Sequential to avoid
    /// spawning N MAME processes in parallel; we can introduce a small
    /// concurrency cap later if needed.
    func verify(ids: Set<Entry.ID>, in system: SystemNode) async {
        let targets = entries(for: system, hideMissing: false).filter { ids.contains($0.id) }
        for entry in targets {
            await verify(entry)
        }
    }

    /// Verify every arcade and software entry. The cache is consulted
    /// first so entries with an unchanged ROM file are accepted instantly.
    /// The remainder are dispatched through a `TaskGroup` with a small
    /// concurrency cap so we don't spawn thousands of MAME processes at
    /// once — but we still saturate cores.
    func verifyAll() async {
        guard let cfg = config, !isVerifyingAll else { return }
        isVerifyingAll = true
        defer {
            isVerifyingAll = false
            arcadeStatus = nil
        }

        var all: [Entry] = arcadeEntries
        for list in softwareLists { all.append(contentsOf: list.entries) }
        let total = all.count

        // First pass: apply cache hits, collect misses.
        var pending: [Entry] = []
        pending.reserveCapacity(total)
        for entry in all {
            if let cached = VerificationCache.freshStatus(for: entry,
                                                          romPaths: cfg.romPaths,
                                                          cache: verificationCache) {
                verifications[entry.id] = cached
            } else {
                pending.append(entry)
            }
        }

        var done = total - pending.count
        arcadeStatus = "Verifying ROMs… \(done)/\(total)"
        guard !pending.isEmpty else { return }

        let exe = cfg.executable
        let romPaths = cfg.romPaths
        let cap = 4

        await withTaskGroup(of: (Entry, RomStatus).self) { group in
            var next = 0
            // Seed initial batch.
            while next < min(cap, pending.count) {
                let entry = pending[next]
                verifyingIDs.insert(entry.id)
                group.addTask {
                    let status = await RomVerifier.verify(entry: entry,
                                                          executable: exe,
                                                          romPaths: romPaths)
                    return (entry, status)
                }
                next += 1
            }
            // Drain + refill.
            while let (entry, status) = await group.next() {
                verifyingIDs.remove(entry.id)
                verifications[entry.id] = status
                verificationCache[entry.id] = VerificationCache.makeRecord(status: status,
                                                                           for: entry,
                                                                           romPaths: romPaths)
                done += 1
                if done % 25 == 0 || done == total {
                    arcadeStatus = "Verifying ROMs… \(done)/\(total)"
                }
                if next < pending.count {
                    let nextEntry = pending[next]
                    verifyingIDs.insert(nextEntry.id)
                    group.addTask {
                        let status = await RomVerifier.verify(entry: nextEntry,
                                                              executable: exe,
                                                              romPaths: romPaths)
                        return (nextEntry, status)
                    }
                    next += 1
                }
            }
        }
        VerificationCache.save(verificationCache)
    }

    // MARK: - ROM downloads

    /// Where a freshly-downloaded ROM should land. We prefer the first
    /// writable directory in the configured `romPaths`; if none exist or
    /// are writable, fall back to `~/Downloads/roms` (matching the user's
    /// original Python script).
    func downloadDestination(for entry: Entry) -> URL? {
        guard case .arcade = entry.kind else { return nil }
        guard let cfg = config else { return nil }
        let fm = FileManager.default
        for dir in cfg.romPaths {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir),
               isDir.boolValue,
               fm.isWritableFile(atPath: dir.path) {
                return dir.appendingPathComponent("\(entry.shortName).zip")
            }
        }
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = downloads.appendingPathComponent("roms", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(entry.shortName).zip")
    }

    /// Download all arcade entries sequentially. Software entries are
    /// silently skipped — the archive.org `mame-merged` item only covers
    /// arcade sets.
    func download(entries targets: [Entry], overwrite: Bool) async {
        let arcade = targets.filter { if case .arcade = $0.kind { true } else { false } }
        let baseURL: String = {
            let stored = UserDefaults.standard.string(forKey: "romDownloadBaseURL") ?? ""
            let trimmed = stored.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? AppSettingsDefaults.romDownloadBaseURL : trimmed
        }()
        for entry in arcade {
            guard let dest = downloadDestination(for: entry) else { continue }
            if !overwrite, FileManager.default.fileExists(atPath: dest.path) { continue }
            downloadingIDs.insert(entry.id)
            downloadStatus = "Downloading \(entry.shortName)…"
            do {
                _ = try await RomDownloader.shared.download(shortName: entry.shortName,
                                                            baseURL: baseURL,
                                                            to: dest)
            } catch {
                loadError = error.localizedDescription
            }
            downloadingIDs.remove(entry.id)
        }
        downloadStatus = nil
        rebuildPresence()
        tagSoftwareOwnership()
        tagArcadeOwnership()
    }
}
