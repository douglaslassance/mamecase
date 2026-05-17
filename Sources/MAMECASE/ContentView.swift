import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: Library
    @AppStorage("showMissingFiles") private var showMissing: Bool = false
    @AppStorage("controllerScheme") private var controllerScheme: String = ""
    @AppStorage("mediaKind") private var mediaKind: MediaKind = .coverArt
    @AppStorage("gridItemSize") private var gridItemSize: Double = 180
    @AppStorage("showStatusBar") private var showStatusBar: Bool = true
    @State private var selection: SystemNode.ID?
    @State private var entrySelection: Set<Entry.ID> = []
    @State private var searchText: String = ""

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

    private var controllerDisplayName: String {
        controllerScheme.isEmpty ? "Default" : controllerScheme
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
                    Label("Show Missing Files", systemImage: "text.page")
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
                    Picker("Controller profile", selection: $controllerScheme) {
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
                }
                .help("MAME -ctrlr profile")
                .disabled(library.controllerSchemes.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showStatusBar {
                StatusBar(selectedEntries: selectedEntries,
                          totalCount: currentNode?.count ?? 0,
                          systemName: currentNode?.displayName,
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
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Systems") {
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
