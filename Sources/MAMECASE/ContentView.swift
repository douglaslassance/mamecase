import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @AppStorage("showMissingFiles") private var showMissing: Bool = false
    @AppStorage("mediaKind") private var mediaKind: MediaKind = .coverArt
    @AppStorage("gridItemSize") private var gridItemSize: Double = 180
    @AppStorage("showStatusBar") private var showStatusBar: Bool = true
    @AppStorage("selectedSystemID") private var persistedSystemID: String = ""
    @State private var selection: SystemNode.ID?
    @State private var entrySelection: Set<Entry.ID> = []
    @State private var searchText: String = ""
    @State private var brewPromptShown: Bool = false
    /// Mirror of the persisted system→scheme map. Kept in sync via the
    /// picker binding; written through to `ControllerSchemes` on edit.
    @State private var schemeMap: [String: String] = ControllerSchemes.all()

    private var systems: [SystemNode] { library.systems(hideMissing: !showMissing) }

    private var currentNode: SystemNode? {
        guard let id = selection else { return nil }
        return systems.first(where: { $0.id == id })
    }

    /// Resolve currently-selected entry IDs to full `Entry` records using
    /// the visible entries of the current system. O(visible entries) and
    /// only called when the status bar renders.
    private var selectedEntries: [Entry] {
        guard let node = currentNode, !entrySelection.isEmpty else { return [] }
        let all = library.entries(for: node, hideMissing: !showMissing)
        return all.filter { entrySelection.contains($0.id) }
    }

    private var currentSchemeForSystem: String {
        guard let id = selection else { return "" }
        return schemeMap[id] ?? ""
    }

    private var controllerDisplayName: String {
        let s = currentSchemeForSystem
        return s.isEmpty ? "Default" : s
    }

    /// Binding into the per-system scheme map. Writes update the in-memory
    /// mirror (so the picker re-renders) and persist via `ControllerSchemes`.
    private var schemeBinding: Binding<String> {
        Binding(
            get: { currentSchemeForSystem },
            set: { newValue in
                guard let id = selection else { return }
                if newValue.isEmpty {
                    schemeMap.removeValue(forKey: id)
                } else {
                    schemeMap[id] = newValue
                }
                ControllerSchemes.set(newValue, for: id)
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showMissing) {
                    Label("Show Missing Files", systemImage: "receipt")
                }
                .toggleStyle(.button)
                .help("Show entries you don't have a ROM for")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Media", selection: $mediaKind) {
                    ForEach(MediaKind.allCases) { kind in
                        Image(systemName: kind.systemImage)
                            .help(kind.label)
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Media displayed in the gallery")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Controller profile", selection: schemeBinding) {
                        Label("Default", systemImage: "gamecontroller").tag("")
                        if !library.controllerSchemes.isEmpty {
                            Divider()
                            ForEach(library.controllerSchemes, id: \.self) { name in
                                Label(name, systemImage: "gamecontroller").tag(name)
                            }
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(controllerDisplayName, systemImage: "gamecontroller")
                        .labelStyle(.titleAndIcon)
                }
                .help("MAME -ctrlr profile (per system)")
                .disabled(library.controllerSchemes.isEmpty || selection == nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showStatusBar {
                StatusBar(selectedEntries: selectedEntries,
                          totalCount: currentNode?.count ?? 0,
                          systemName: currentNode?.displayName,
                          verifications: library.verifications,
                          gridItemSize: $gridItemSize)
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
        .onChange(of: systems) { _, newSystems in
            restoreSelectionIfNeeded(in: newSystems)
        }
        .onChange(of: selection) { _, new in
            if let new { persistedSystemID = new }
        }
        .onAppear {
            restoreSelectionIfNeeded(in: systems)
        }
    }

    /// Pick a sidebar selection automatically: restore the last-used system
    /// if it still exists, otherwise fall back to the first available.
    private func restoreSelectionIfNeeded(in nodes: [SystemNode]) {
        guard !nodes.isEmpty else { return }
        if let current = selection, nodes.contains(where: { $0.id == current }) {
            return
        }
        if !persistedSystemID.isEmpty,
           nodes.contains(where: { $0.id == persistedSystemID }) {
            selection = persistedSystemID
        } else {
            selection = nodes.first?.id
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(systems) { node in
                HStack {
                    Text(node.displayName)
                        .lineLimit(1)
                    Spacer()
                    Text("\(node.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(Optional(node.id))
            }
        }
        .navigationTitle("Mamecase")
        .frame(minWidth: 220)
        .overlay(alignment: .bottom) {
            if let status = library.arcadeStatus {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if library.isLoading && systems.isEmpty {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let node = currentNode {
            GalleryView(system: node,
                        hideMissing: !showMissing,
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
