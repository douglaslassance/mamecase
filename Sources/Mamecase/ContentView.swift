import SwiftUI

/// `Label` style that mirrors macOS toolbar layout but with breathable
/// spacing between the icon and the title. Default `.titleAndIcon`
/// gives a too-tight gap once the icon is an SF Symbol with intrinsic
/// padding.
private struct SpacedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @AppStorage("showMissingFiles") private var showMissing: Bool = false
    @AppStorage("showFavoritesOnly") private var showFavoritesOnly: Bool = false
    @AppStorage("showFailingOnly") private var showFailingOnly: Bool = false
    @AppStorage("mediaKind") private var mediaKind: MediaKind = .flyers
    @AppStorage("gridItemSize") private var gridItemSize: Double = 180
    @AppStorage("showStatusBar") private var showStatusBar: Bool = true
    @AppStorage("showInspector") private var showInspector: Bool = false
    @AppStorage("selectedSystemID") private var persistedSystemID: String = ""
    /// Not `@AppStorage` any more. The controller profile is stored per
    /// system and per connected-pad set, so this mirrors whatever
    /// `ControllerProfileStore` holds for the current pairing and is
    /// resynced whenever the system or the plugged-in hardware changes.
    @State private var controllerScheme: String = ""
    @ObservedObject private var controllers = ControllerDetector.shared
    @AppStorage("shaderScheme") private var shaderScheme: String = ""
    @AppStorage("regionFilter") private var regionFilter: RegionFilter = .all
    @AppStorage("layoutMode") private var layoutMode: LayoutMode = .horizontalMasonry
    @State private var selection: SystemNode.ID?
    @State private var entrySelection: Set<Entry.ID> = []
    @State private var searchText: String = ""
    @State private var brewPromptShown: Bool = false
    @State private var sevenZipPromptShown: Bool = false
    @State private var showNewPlaylistSheet: Bool = false
    @State private var newPlaylistName: String = ""

    private var systems: [SystemNode] { library.systems(hideMissing: !showMissing) }

    private var librarySystems: [SystemNode] {
        let total = library.arcadeEntries.count
            + library.softwareLists.reduce(0) { $0 + $1.entries.count }
        return [
            SystemNode(id: "library/all",
                       displayName: "All",
                       count: total,
                       kind: .cross(scope: .all)),
            SystemNode(id: "library/recent",
                       displayName: "Recent",
                       count: library.recentlyLaunched.count,
                       kind: .cross(scope: .recent)),
        ]
    }

    private var playlistSystems: [SystemNode] {
        library.playlists.map { playlist in
            SystemNode(id: "playlist/\(playlist.id)",
                       displayName: playlist.name,
                       count: playlist.entryIDs.count,
                       kind: .cross(scope: .playlist(id: playlist.id)))
        }
    }

    private var sidebarSystems: [SystemNode] { librarySystems + systems + playlistSystems }

    private var currentNode: SystemNode? {
        guard let id = selection else { return nil }
        return sidebarSystems.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func sidebarRow(_ node: SystemNode) -> some View {
        HStack {
            Label {
                Text(node.displayName).lineLimit(1)
            } icon: {
                Image(systemName: node.kind.sidebarIcon)
            }
            Spacer()
            Text("\(filteredCount(for: node))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
        }
        .tag(Optional(node.id))
    }

    /// Same filters the gallery applies, so the sidebar count matches
    /// what the user actually sees: missing toggle + favourites only +
    /// region. Search is intentionally NOT applied — it's a per-system
    /// view-level concern, not a global library filter.
    private func filteredCount(for node: SystemNode) -> Int {
        library.filteredCount(for: node,
                              filter: EntryFilter(hideMissing: !showMissing,
                                                  favoritesOnly: showFavoritesOnly,
                                                  failingOnly: showFailingOnly,
                                                  region: regionFilter))
    }

    /// Resolve currently-selected entry IDs to full `Entry` records using
    /// the visible entries of the current system. O(visible entries) and
    /// only called when the status bar renders.
    private var selectedEntries: [Entry] {
        guard let node = currentNode, !entrySelection.isEmpty else { return [] }
        let all = library.entries(for: node, hideMissing: !showMissing)
        return all.filter { entrySelection.contains($0.id) }
    }

    /// `nil` on cross-system nodes, where the profile picker is hidden.
    private var currentSystemToken: String? { currentNode?.kind.systemToken }

    private var controllerActive: Bool { !controllerScheme.isEmpty }

    /// Names the pairing the choice will be remembered against, so it is
    /// obvious the menu is scoped and not global.
    private var connectedControllerSummary: String {
        let pads = controllers.connected
        guard !pads.isEmpty else { return "No controller connected" }
        return pads.map(\.name).joined(separator: " + ")
    }

    /// Pull the stored profile for the current pairing into the picker.
    private func syncControllerScheme() {
        guard let system = currentSystemToken else { return }
        controllerScheme = ControllerProfileStore.profile(system: system,
                                                          devices: controllers.connected)
    }

    /// Teaching gesture. Whatever the user picks is remembered for this
    /// system paired with exactly the pads currently plugged in.
    private var controllerSchemeBinding: Binding<String> {
        Binding(get: { controllerScheme },
                set: { newValue in
                    controllerScheme = newValue
                    guard let system = currentSystemToken else { return }
                    ControllerProfileStore.setProfile(newValue,
                                                      system: system,
                                                      devices: controllers.connected)
                })
    }

    private var shaderActive: Bool { !shaderScheme.isEmpty }

    private var singleSelectedEntry: Entry? {
        selectedEntries.count == 1 ? selectedEntries[0] : nil
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            HStack(spacing: 0) {
                detail
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if showStatusBar {
                            StatusBar(selectedEntries: selectedEntries,
                                      totalCount: currentNode?.count ?? 0,
                                      systemName: currentNode?.displayName,
                                      verifications: library.verifications,
                                      busyStatus: library.arcadeStatus,
                                      gridItemSize: $gridItemSize)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    Divider()
                    EntryInspector(entry: singleSelectedEntry)
                        .frame(width: 320)
                }
            }
        }
        .toolbar {
            ToolbarItem(id: "show-favorites", placement: .primaryAction) {
                Toggle(isOn: $showFavoritesOnly) {
                    Label("Favorites Only", systemImage: "star.fill")
                }
                .toggleStyle(.button)
                .help("Only show favorited entries")
            }
            ToolbarItem(id: "show-missing", placement: .primaryAction) {
                Toggle(isOn: $showMissing) {
                    Label("Show Missing Files", systemImage: "receipt")
                }
                .toggleStyle(.button)
                .help("Show entries you don't have a ROM for")
            }
            ToolbarItem(id: "show-failing", placement: .primaryAction) {
                Toggle(isOn: $showFailingOnly) {
                    Label("Failing Verification Only", systemImage: "exclamationmark.shield")
                }
                .toggleStyle(.button)
                .help("Only show ROMs whose verification is bad, best-available, or errored")
            }
            ToolbarItem(id: "media-kind", placement: .primaryAction) {
                Picker("Media", selection: $mediaKind) {
                    ForEach(MediaKind.allCases) { kind in
                        Image(systemName: kind.systemImage).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Media displayed in the gallery")
            }
            ToolbarItem(id: "layout-mode", placement: .primaryAction) {
                Picker("Layout", selection: $layoutMode) {
                    ForEach(LayoutMode.allCases) { mode in
                        Image(moduleSymbol: mode.moduleSymbol)
                            .help(mode.label)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Gallery layout")
            }
            ToolbarItem(id: "region-filter", placement: .primaryAction) {
                Picker("Region", selection: $regionFilter) {
                    ForEach(RegionFilter.allCases) { region in
                        Text(region.emoji).tag(region)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Filter by region")
            }
            ToolbarItem(id: "controller-scheme", placement: .primaryAction) {
                // Hidden on All, Recent and playlists. Those span several
                // systems, so there is no single profile to show. Launching
                // from them still resolves per entry.
                if currentSystemToken != nil {
                    Menu {
                        Section(connectedControllerSummary) {
                            Picker("Controller profile", selection: controllerSchemeBinding) {
                                Text("Default").tag("")
                                if !library.controllerSchemes.isEmpty {
                                    Divider()
                                    ForEach(library.controllerSchemes, id: \.self) { name in
                                        Text(name).tag(name)
                                    }
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    } label: {
                        Image(systemName: "gamecontroller")
                            .foregroundStyle(controllerActive ? Color.accentColor : Color.primary)
                    }
                    .help("MAME -ctrlr profile, remembered for this system and these controllers")
                    .disabled(library.controllerSchemes.isEmpty)
                }
            }
            ToolbarItem(id: "shader-scheme", placement: .primaryAction) {
                Menu {
                    Picker("Shader", selection: $shaderScheme) {
                        Text("Default").tag("")
                        if !library.shaderSchemes.isEmpty {
                            Divider()
                            ForEach(library.shaderSchemes, id: \.self) { name in
                                Text(displayShaderName(name)).tag(name)
                            }
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(shaderActive ? Color.accentColor : Color.primary)
                }
                .help("GLSL shader override (slot 1)")
                .disabled(library.shaderSchemes.isEmpty)
            }
        }
        .alert("Error",
               isPresented: Binding(get: { library.loadError != nil },
                                    set: { if !$0 { library.loadError = nil } })) {
            Button("OK") { library.loadError = nil }
        } message: {
            Text(library.loadError ?? "")
        }
        .alert("Install MAME via Homebrew?",
               isPresented: $brewPromptShown) {
            Button("Install") {
                Task { await library.installMameViaBrew(settings: settings) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("MAME isn't on your PATH but Homebrew is. Install it now? This may take a couple of minutes.")
        }
        .onChange(of: library.mameMissing) { _, missing in
            if missing && library.brewAvailable && !library.installingMame {
                brewPromptShown = true
            }
        }
        .alert("Install 7-Zip via Homebrew?",
               isPresented: $sevenZipPromptShown) {
            Button("Install") { Task { await library.installSevenZipViaBrew() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Mamecase found a `.7z` media archive but `7zz` isn't installed. Install it now? This takes about a minute.")
        }
        .onChange(of: library.sevenZipMissing) { _, missing in
            if missing && BrewInstaller.brewExecutable() != nil && !library.installingSevenZip {
                sevenZipPromptShown = true
            }
        }
        .onChange(of: sidebarSystems) { _, newSystems in
            restoreSelectionIfNeeded(in: newSystems)
        }
        .onChange(of: controllers.connected) { _, _ in
            syncControllerScheme()
        }
        .onChange(of: selection) { _, new in
            if let new { persistedSystemID = new }
            syncControllerScheme()
            // Clearing the search on system change matches Finder /
            // Mail / Notes — search scope is implicitly per-folder.
            searchText = ""
        }
        .onAppear {
            restoreSelectionIfNeeded(in: sidebarSystems)
            syncControllerScheme()
        }
    }

    private func displayShaderName(_ full: String) -> String {
        if let slash = full.firstIndex(of: "/") {
            return String(full[full.index(after: slash)...])
        }
        return full
    }

    /// Pick a sidebar selection automatically: restore the last-used system
    /// if it still exists, otherwise fall back to the first available.
    /// The trick is that `.onAppear` runs before the library has parsed
    /// software lists, so `sidebarSystems` initially only contains the
    /// always-present library cross-systems (All / Recent). If we
    /// auto-picked the first node here, the `.onChange(of: selection)`
    /// handler would persist that default and clobber the user's saved
    /// pick. So while the library is still loading, we wait for the
    /// persisted node to materialise rather than commit to a fallback.
    private func restoreSelectionIfNeeded(in nodes: [SystemNode]) {
        guard !nodes.isEmpty else { return }
        if let current = selection, nodes.contains(where: { $0.id == current }) {
            return
        }
        if !persistedSystemID.isEmpty,
           nodes.contains(where: { $0.id == persistedSystemID }) {
            selection = persistedSystemID
            return
        }
        if !persistedSystemID.isEmpty, library.isLoading {
            return
        }
        selection = nodes.first?.id
    }

    private var sidebar: some View {
        List(selection: $selection) {
            // No section header for the top group — matches the iTunes /
            // Finder sidebar idiom where the first batch is unlabeled.
            Section {
                ForEach(librarySystems) { node in sidebarRow(node) }
            }
            if !systems.isEmpty {
                Section("Systems") {
                    ForEach(systems) { node in sidebarRow(node) }
                }
            }
            Section {
                ForEach(playlistSystems) { node in
                    sidebarRow(node)
                        .contextMenu {
                            Button("Rename…") { /* TODO: rename sheet */ }
                            Button(role: .destructive) {
                                if case .cross(let scope) = node.kind,
                                   case .playlist(let id) = scope {
                                    library.deletePlaylist(id: id)
                                }
                            } label: { Text("Delete") }
                        }
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button {
                        newPlaylistName = ""
                        showNewPlaylistSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Playlist")
                }
            }
        }
        .navigationTitle("Mamecase")
        .sheet(isPresented: $showNewPlaylistSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Playlist").font(.headline)
                TextField("Name", text: $newPlaylistName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        showNewPlaylistSheet = false
                    }
                    .keyboardShortcut(.escape)
                    Button("Create") {
                        let p = library.createPlaylist(named: newPlaylistName)
                        showNewPlaylistSheet = false
                        selection = "playlist/\(p.id)"
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if library.mameMissing {
            SetupView()
        } else if library.isLoading && systems.isEmpty {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let node = currentNode {
            GalleryView(system: node,
                        hideMissing: !showMissing,
                        showFavoritesOnly: showFavoritesOnly,
                        showFailingOnly: showFailingOnly,
                        regionFilter: regionFilter,
                        layoutMode: layoutMode,
                        clearFilters: {
                            showFavoritesOnly = false
                            showFailingOnly = false
                            regionFilter = .all
                        },
                        enableShowMissing: { showMissing = true },
                        searchText: $searchText,
                        selection: $entrySelection)
                .id(node.id)
        } else {
            ContentUnavailableView("Select a system",
                                   systemImage: "gamecontroller",
                                   description: Text("Pick a system from the sidebar."))
        }
    }
}
