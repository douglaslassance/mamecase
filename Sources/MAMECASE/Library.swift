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
    @Published var verifications: [Entry.ID: RomStatus] = [:]
    @Published var verifyingIDs: Set<Entry.ID> = []
    @Published var downloadingIDs: Set<Entry.ID> = []
    @Published var downloadStatus: String?
    @Published var mameMissing: Bool = false
    @Published var brewAvailable: Bool = false
    @Published var installingMame: Bool = false
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

    func entries(for system: SystemNode, hideMissing: Bool) -> [Entry] {
        let all: [Entry]
        switch system.kind {
        case .arcade:
            all = arcadeEntries
        case .software(let name):
            all = softwareLists.first(where: { $0.name == name })?.entries ?? []
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
        arcadeStatus = "Running mame -listfull…"
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

    /// Kick off a one-time bulk extraction for `kind` if archives exist on
    /// disk. Cheap to call from many tiles; the actor inside MediaProvider
    /// deduplicates work per archive.
    func requestMediaExtraction(for kind: MediaKind) {
        guard let cfg = config else { return }
        if extractingMedia.contains(kind) { return }
        extractingMedia.insert(kind)
        arcadeStatus = "Extracting \(kind.label) archive…"
        Task { [weak self] in
            let didWork = await MediaProvider.shared.extractArchivesIfNeeded(kind: kind, config: cfg)
            await MainActor.run {
                guard let self else { return }
                self.extractingMedia.remove(kind)
                if self.extractingMedia.isEmpty { self.arcadeStatus = nil }
                if didWork { self.mediaGeneration &+= 1 }
            }
        }
    }

    func launch(_ entry: Entry) {
        guard let cfg = config else { return }
        let scheme = ControllerSchemes.scheme(for: ControllerSchemes.systemID(for: entry))
        do {
            try MameLauncher.launch(executable: cfg.executable,
                                    args: MameLauncher.arguments(for: entry,
                                                                 romPaths: cfg.romPaths,
                                                                 controllerScheme: scheme),
                                    workingDirectory: cfg.homePath)
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

    /// Run MAME's audit for one entry and record the result.
    func verify(_ entry: Entry) async {
        guard let cfg = config else { return }
        verifyingIDs.insert(entry.id)
        defer { verifyingIDs.remove(entry.id) }
        let status = await RomVerifier.verify(entry: entry,
                                              executable: cfg.executable,
                                              romPaths: cfg.romPaths)
        verifications[entry.id] = status
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
        for entry in arcade {
            guard let dest = downloadDestination(for: entry) else { continue }
            if !overwrite, FileManager.default.fileExists(atPath: dest.path) { continue }
            downloadingIDs.insert(entry.id)
            downloadStatus = "Downloading \(entry.shortName)…"
            do {
                _ = try await RomDownloader.shared.download(shortName: entry.shortName, to: dest)
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
