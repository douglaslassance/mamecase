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
            rebuildControllerSchemes()

            // Hydrate arcade entries from disk cache so the gallery is usable
            // immediately. The fresh `mame -listfull` re-index runs in the
            // background below.
            if let cached = ArcadeCache.load() {
                self.arcadeEntries = cached
            }

            await loadSoftwareLists(cfg: cfg)
            rebuildPresence()
            tagSoftwareOwnership()
            tagArcadeOwnership()

            // Kick off the slow refresh without blocking startup.
            Task { [weak self] in
                await self?.indexArcade()
            }
        } catch {
            self.loadError = error.localizedDescription
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

    func snapshotURL(for entry: Entry) -> URL? {
        guard let cfg = config else { return nil }
        let fm = FileManager.default
        let subdir: String
        switch entry.kind {
        case .arcade: subdir = entry.shortName
        case .software(let sys): subdir = "\(sys)/\(entry.shortName)"
        }
        for snap in cfg.snapPaths {
            let candidates = [
                snap.appendingPathComponent("\(subdir).png"),
                snap.appendingPathComponent(subdir).appendingPathComponent("0000.png"),
                snap.appendingPathComponent(subdir).appendingPathComponent("snap.png")
            ]
            for c in candidates where fm.fileExists(atPath: c.path) {
                return c
            }
        }
        return nil
    }

    /// Resolves "cover art" for an entry, the abstraction being:
    ///   - arcade   → flyer (`flyers_directory/<short>.{png,jpg,jpeg}`)
    ///   - software → user-supplied cover (`covers/<list>/<short>.{png,jpg,jpeg}`)
    func coverURL(for entry: Entry) -> URL? {
        guard let cfg = config else { return nil }
        let fm = FileManager.default
        let exts = ["png", "jpg", "jpeg"]
        let dirs: [URL]
        let basename: String
        switch entry.kind {
        case .arcade:
            dirs = cfg.flyerPaths
            basename = entry.shortName
        case .software(let sys):
            dirs = cfg.coverPaths
            basename = "\(sys)/\(entry.shortName)"
        }
        for dir in dirs {
            for ext in exts {
                let url = dir.appendingPathComponent("\(basename).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    func launch(_ entry: Entry) {
        guard let cfg = config else { return }
        let scheme = UserDefaults.standard.string(forKey: "controllerScheme")
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
}
