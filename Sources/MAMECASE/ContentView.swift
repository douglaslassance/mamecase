import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: Library
    @AppStorage("showMissingFiles") private var showMissing: Bool = false
    @AppStorage("controllerScheme") private var controllerScheme: String = ""
    @AppStorage("artworkMode") private var artworkMode: ArtworkMode = .coverArt
    @AppStorage("gridItemSize") private var gridItemSize: Double = 180
    @State private var selection: SystemNode.ID?
    @State private var searchText: String = ""

    private var systems: [SystemNode] { library.systems(hideMissing: !showMissing) }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showMissing) {
                    Label("Show Missing Files",
                          systemImage: showMissing ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .help("Show entries you don't have a ROM for")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Artwork", selection: $artworkMode) {
                    ForEach(ArtworkMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .help(mode.label)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Artwork displayed in the gallery")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Controller profile", selection: $controllerScheme) {
                    Label("Default", systemImage: "gamecontroller").tag("")
                    if !library.controllerSchemes.isEmpty {
                        Divider()
                        ForEach(library.controllerSchemes, id: \.self) { name in
                            Label(name, systemImage: "gamecontroller").tag(name)
                        }
                    }
                }
                .pickerStyle(.menu)
                .help("MAME -ctrlr profile")
                .disabled(library.controllerSchemes.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await library.indexArcade() }
                } label: {
                    Label(library.arcadeIndexing ? "Indexing…" : "Index Arcade",
                          systemImage: "arrow.clockwise")
                }
                .disabled(library.arcadeIndexing || library.config == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Slider(value: $gridItemSize, in: 120...320) {
                    Text("Tile size")
                } minimumValueLabel: {
                    Image(systemName: "square.grid.4x3.fill").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "square.grid.2x2.fill").imageScale(.small)
                }
                .frame(width: 140)
                .help("Tile size")
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
        .navigationTitle("MAMECASE")
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
        } else if let id = selection,
                  let node = systems.first(where: { $0.id == id }) {
            GalleryView(system: node, hideMissing: !showMissing, searchText: $searchText)
                .id(node.id)
        } else {
            ContentUnavailableView("Select a system",
                                   systemImage: "gamecontroller",
                                   description: Text("Pick a system from the sidebar."))
        }
    }
}
