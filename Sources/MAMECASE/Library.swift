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
    /// Per-entry tooltip detail string captured from the audit output
    /// (e.g. "ROM xxx: BAD CRC"). Populated alongside `verifications`.
    @Published var verificationDetails: [Entry.ID: String] = [:]
    @Published var verifyingIDs: Set<Entry.ID> = []
    @Published var favorites: Set<Entry.ID> = FavoritesStore.load()
    /// Entry IDs in launch order, most recent first. Populated by
    /// `launch(_:)`; persisted in Phase 4.
    @Published var recentlyLaunched: [Entry.ID] = RecentsStore.load()
    /// User-curated lists of entries. Persisted as JSON.
    @Published var playlists: [Playlist] = PlaylistsStore.load()
    @Published var isVerifyingAll: Bool = false
    /// In-memory mirror of `verifications.json` so we can decide cache hits
    /// without touching disk on every entry.
    private var verificationCache: [Entry.ID: VerificationCache.Record] = [:]
    @Published var downloadingIDs: Set<Entry.ID> = []
    @Published var downloadStatus: String?
    @Published var mameMissing: Bool = false
    @Published var brewAvailable: Bool = false
    @Published var installingMame: Bool = false
    @Published var mameBrewManaged: Bool = false
    @Published var mameUpdateAvailable: Bool = false
    @Published var upgradingMame: Bool = false
    /// First line of `mame -help` (e.g. `MAME v0.260 (mame0260)`). Nil
    /// until the probe completes or if the binary doesn't respond.
    @Published var mameVersion: String?
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
            var statusMap: [Entry.ID: RomStatus] = [:]
            var detailMap: [Entry.ID: String] = [:]
            statusMap.reserveCapacity(verificationCache.count)
            for (id, record) in verificationCache {
                statusMap[id] = record.status
                if let d = record.details { detailMap[id] = d }
            }
            self.verifications = statusMap
            self.verificationDetails = detailMap

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

            // Brew-manage check + update probe runs in the background; the
            // gear-button badge picks it up via @Published.
            mameBrewManaged = BrewInstaller.isMameBrewManaged()
            if mameBrewManaged {
                Task { [weak self] in
                    let outdated = await BrewInstaller.isMameOutdated()
                    await MainActor.run { self?.mameUpdateAvailable = outdated }
                }
            } else {
                mameUpdateAvailable = false
            }

            // Probe the MAME version banner, then kick off background
            // verification. The version is part of the verification
            // cache key — without it freshStatus rejects every record
            // and we'd re-audit the whole library on every launch.
            let exe = cfg.executable
            Task { [weak self] in
                let v = await BrewInstaller.mameVersion(executable: exe)
                await MainActor.run { self?.mameVersion = v }
                await self?.verifyAll()
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
        guard !installingMame else { return }
        guard BrewInstaller.brewExecutable() != nil else {
            loadError = "Homebrew not installed."
            return
        }
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

    /// Run `brew upgrade mame` and reload on success.
    func upgradeMameViaBrew(settings: AppSettings) async {
        guard !upgradingMame, mameBrewManaged else { return }
        upgradingMame = true
        arcadeStatus = "brew upgrade mame…"
        let code = await BrewInstaller.upgradeMame()
        arcadeStatus = nil
        upgradingMame = false
        if code == 0 {
            mameUpdateAvailable = false
            await load(settings: settings)
        } else {
            loadError = "Homebrew upgrade failed (exit code \(code))."
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

    /// Re-run the full media-resolution chain for a batch of entries.
    /// For each entry:
    ///   1. Invalidate cached files + online-miss markers so we start
    ///      from scratch.
    ///   2. Ensure sibling archives have been extracted (snap.7z,
    ///      flyers.zip, …); the actor dedupes work per archive.
    ///   3. Check `MediaProvider.url(...)` — that covers loose files in
    ///      the configured paths AND files unpacked into the cache by
    ///      step 2.
    ///   4. If still nothing, fall through to `fetchOnline`.
    /// Bumps `mediaGeneration` so visible tiles refresh.
    /// Works for both owned and unowned entries — the right-click action
    /// is explicit, so the auto-fetch gate in `EntryTile.resolveMedia`
    /// doesn't apply.
    func updateMedia(ids: Set<Entry.ID>, in system: SystemNode) async {
        guard let cfg = config else { return }
        let targets = entries(for: system, hideMissing: false).filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        arcadeStatus = "Updating media…"
        defer {
            arcadeStatus = nil
            mediaGeneration &+= 1
        }

        // 1. Wipe cached files + miss markers for every target.
        for entry in targets {
            await MediaProvider.shared.invalidate(entry: entry)
        }

        // 2. Make sure archives have been unpacked (idempotent per
        //    archive URL). The first call after launch does real work;
        //    subsequent calls are near-instant.
        for kind in MediaKind.allCases {
            _ = await MediaProvider.shared.extractArchivesIfNeeded(kind: kind, config: cfg)
        }

        // 3 + 4. For each entry/kind, prefer a local file (loose or
        //        archive-extracted), fall back to online.
        var done = 0
        for entry in targets {
            for kind in MediaKind.allCases {
                if MediaProvider.url(for: entry, kind: kind, config: cfg) != nil { continue }
                _ = await MediaProvider.shared.fetchOnline(for: entry, kind: kind)
            }
            done += 1
            if done % 5 == 0 || done == targets.count {
                arcadeStatus = "Updating media… \(done)/\(targets.count)"
            }
        }
    }

    // MARK: - Favorites

    // MARK: - Deleting ROMs

    /// Delete the on-disk ROM file (zip / 7z / chd) for every entry in
    /// `ids`. Returns the count actually removed. Caller is expected to
    /// confirm with the user first — this is destructive.
    @discardableResult
    func deleteROMs(ids: Set<Entry.ID>, in system: SystemNode) -> Int {
        guard let cfg = config else { return 0 }
        let targets = entries(for: system, hideMissing: false).filter { ids.contains($0.id) }
        let fm = FileManager.default
        var removed = 0
        for entry in targets {
            if let url = VerificationCache.romFile(for: entry, in: cfg.romPaths) {
                if (try? fm.removeItem(at: url)) != nil {
                    removed += 1
                    verifications.removeValue(forKey: entry.id)
                }
            }
        }
        if removed > 0 {
            rebuildPresence()
            tagSoftwareOwnership()
            tagArcadeOwnership()
        }
        return removed
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let final = trimmed.isEmpty ? "Untitled Playlist" : trimmed
        let p = Playlist(id: UUID().uuidString, name: final, entryIDs: [])
        playlists.append(p)
        PlaylistsStore.save(playlists)
        return p
    }

    func deletePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
        PlaylistsStore.save(playlists)
    }

    func renamePlaylist(id: String, to name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
        PlaylistsStore.save(playlists)
    }

    func addToPlaylist(_ playlistID: String, entryIDs: Set<Entry.ID>) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for id in entryIDs where !playlists[idx].entryIDs.contains(id) {
            playlists[idx].entryIDs.append(id)
        }
        PlaylistsStore.save(playlists)
    }

    func removeFromPlaylist(_ playlistID: String, entryIDs: Set<Entry.ID>) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].entryIDs.removeAll { entryIDs.contains($0) }
        PlaylistsStore.save(playlists)
    }

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
        let result = await RomVerifier.verify(entry: entry,
                                              executable: cfg.executable,
                                              romPaths: cfg.romPaths)
        verifications[entry.id] = result.status
        if let d = result.details {
            verificationDetails[entry.id] = d
        } else {
            verificationDetails.removeValue(forKey: entry.id)
        }
        verificationCache[entry.id] = VerificationCache.makeRecord(status: result.status,
                                                                   details: result.details,
                                                                   for: entry,
                                                                   romPaths: cfg.romPaths,
                                                                   mameVersion: mameVersion)
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

    /// Verify every owned arcade and software entry. The cache is
    /// consulted first so entries with an unchanged ROM file are accepted
    /// instantly. The remainder are dispatched through a `TaskGroup` with
    /// a small concurrency cap so we don't spawn thousands of MAME
    /// processes at once — but we still saturate cores. Skips entries
    /// the user doesn't own: their ROM file is by definition absent, so
    /// the MAME audit only confirms what `tagOwnership` already told us.
    func verifyAll() async {
        guard let cfg = config, !isVerifyingAll else { return }
        isVerifyingAll = true
        defer {
            isVerifyingAll = false
            arcadeStatus = nil
        }

        var all: [Entry] = arcadeEntries.filter(\.owned)
        for list in softwareLists {
            all.append(contentsOf: list.entries.filter(\.owned))
        }
        let total = all.count

        // First pass: apply cache hits, collect misses. A nil
        // `mameVersion` causes `freshStatus` to reject every record,
        // which would defeat the cache entirely — so we abort early
        // and rely on `load()` re-calling us after the version probe
        // lands.
        guard let currentMameVersion = mameVersion else { return }

        // Build the cache-hit map locally and publish ONCE. The old
        // implementation wrote `verifications[entry.id] = cached`
        // inside the loop, triggering an objectWillChange per entry —
        // 9k publishes on a typical library, each forcing the whole
        // gallery to re-render. That's the perf cliff the user hit.
        var statusUpdates = verifications
        var pending: [Entry] = []
        pending.reserveCapacity(total)
        for entry in all {
            if let cached = VerificationCache.freshStatus(for: entry,
                                                          romPaths: cfg.romPaths,
                                                          cache: verificationCache,
                                                          mameVersion: currentMameVersion) {
                statusUpdates[entry.id] = cached
            } else {
                pending.append(entry)
            }
        }
        verifications = statusUpdates

        var done = total - pending.count
        arcadeStatus = "Verifying ROMs… \(done)/\(total)"
        guard !pending.isEmpty else { return }

        let exe = cfg.executable
        let romPaths = cfg.romPaths
        // Lower concurrency for the background pass. Two parallel
        // `mame -verifyroms` processes is plenty — they're disk-bound
        // and we don't want the audit to fight the UI for CPU.
        let cap = 2
        // Flush updates to @Published storage every N completions so
        // the gallery re-renders ~periodically instead of per-entry.
        // Larger batches mean fewer ContentView body recomputes (each
        // walks every sidebar pill via `filteredCount`), so coarser
        // here = smoother scroll while the audit runs.
        let flushEvery = 200

        // NB: we deliberately don't touch `verifyingIDs` inside the
        // bulk loop. It's @Published, and toggling it twice per entry
        // (insert before, remove after) over thousands of entries was
        // the main source of UI stalls — each mutation fires
        // objectWillChange on Library, which re-renders ContentView
        // and walks every sidebar pill via `filteredCount`. Per-tile
        // spinners during a 9k-entry pass aren't worth that cost; the
        // status bar already shows aggregate progress.

        await withTaskGroup(of: (Entry, RomVerifier.Result).self) { group in
            var next = 0
            // Seed initial batch.
            while next < min(cap, pending.count) {
                let entry = pending[next]
                group.addTask {
                    let result = await RomVerifier.verify(entry: entry,
                                                          executable: exe,
                                                          romPaths: romPaths)
                    return (entry, result)
                }
                next += 1
            }

            // Accumulate results locally; flush in chunks.
            var pendingStatus: [Entry.ID: RomStatus] = [:]
            var pendingDetails: [Entry.ID: String?] = [:]
            var sinceFlush = 0

            @MainActor func flush() {
                guard !pendingStatus.isEmpty else { return }
                verifications.merge(pendingStatus, uniquingKeysWith: { _, new in new })
                for (id, value) in pendingDetails {
                    if let v = value { verificationDetails[id] = v }
                    else { verificationDetails.removeValue(forKey: id) }
                }
                pendingStatus.removeAll(keepingCapacity: true)
                pendingDetails.removeAll(keepingCapacity: true)
                sinceFlush = 0
            }

            // Drain + refill.
            while let (entry, result) = await group.next() {
                pendingStatus[entry.id] = result.status
                pendingDetails[entry.id] = result.details
                verificationCache[entry.id] = VerificationCache.makeRecord(status: result.status,
                                                                           details: result.details,
                                                                           for: entry,
                                                                           romPaths: romPaths,
                                                                           mameVersion: currentMameVersion)
                done += 1
                sinceFlush += 1
                if sinceFlush >= flushEvery || done == total {
                    flush()
                    arcadeStatus = "Verifying ROMs… \(done)/\(total)"
                }
                if next < pending.count {
                    let nextEntry = pending[next]
                    group.addTask {
                        let r = await RomVerifier.verify(entry: nextEntry,
                                                         executable: exe,
                                                         romPaths: romPaths)
                        return (nextEntry, r)
                    }
                    next += 1
                }
            }
            flush()
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
