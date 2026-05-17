import SwiftUI
import AppKit

struct GalleryView: View {
    @EnvironmentObject var library: Library
    let system: SystemNode
    let hideMissing: Bool
    @Binding var searchText: String

    @AppStorage("gridItemSize") private var gridItemSize: Double = 180
    @State private var selection: Set<Entry.ID> = []
    @State private var anchor: Entry.ID?
    @FocusState private var focused: Bool

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: gridItemSize, maximum: gridItemSize * 1.4), spacing: 16)]
    }

    private var entries: [Entry] {
        let all = library.entries(for: system, hideMissing: hideMissing)
        guard !searchText.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.shortName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(entries) { entry in
                    EntryTile(entry: entry,
                              snapURL: library.mediaURL(for: entry, kind: .snap),
                              coverURL: library.mediaURL(for: entry, kind: .coverArt),
                              selected: selection.contains(entry.id))
                        .contentShape(Rectangle())
                        .overlay(
                            MouseEventView { clickCount in
                                if clickCount >= 2 {
                                    library.launch(entry)
                                } else {
                                    handleClick(entry)
                                }
                            }
                        )
                        .contextMenu {
                            Button("Launch") {
                                if selection.contains(entry.id), selection.count > 1 {
                                    library.launch(ids: selection, in: system)
                                } else {
                                    library.launch(entry)
                                }
                            }
                            Divider()
                            if let snap = library.mediaURL(for: entry, kind: .snap) {
                                Button("Reveal Snapshot in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([snap])
                                }
                            }
                            Button("Copy Short Name") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.shortName, forType: .string)
                            }
                        }
                }
            }
            .padding(16)
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection.removeAll() }
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.return) {
            if !selection.isEmpty {
                library.launch(ids: selection, in: system)
                return .handled
            }
            return .ignored
        }
        .onChange(of: system.id) { _, _ in
            selection.removeAll()
            anchor = nil
        }
        .navigationTitle(system.displayName)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search \(system.displayName)")
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No entries",
                                       systemImage: "tray",
                                       description: Text(emptyHint))
            }
        }
    }

    private var emptyHint: String {
        switch system.kind {
        case .arcade where library.arcadeEntries.isEmpty:
            return "Click ‘Index Arcade’ to scan."
        case .arcade:
            return hideMissing ? "No ROMs found in your rompath. Turn off ‘Hide missing’ to browse all."
                               : "No arcade entries match your search."
        case .software:
            return hideMissing ? "No ROMs for this system in your rompath. Turn off ‘Hide missing’ to browse all."
                               : "Nothing matched your search."
        }
    }

    // MARK: - Selection

    private func handleClick(_ entry: Entry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
                anchor = entry.id
            }
        } else if flags.contains(.shift), let anchor,
                  let from = entries.firstIndex(where: { $0.id == anchor }),
                  let to = entries.firstIndex(where: { $0.id == entry.id }) {
            let range = from <= to ? from...to : to...from
            selection = Set(entries[range].map(\.id))
        } else {
            selection = [entry.id]
            anchor = entry.id
        }
    }
}

private struct EntryTile: View {
    let entry: Entry
    let snapURL: URL?
    let coverURL: URL?
    let selected: Bool

    @AppStorage("mediaKind") private var mediaKind: MediaKind = .coverArt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                if let image = preferredImage() {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(4.0/3.0, contentMode: .fit)

            Text(entry.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Keep this row a fixed height so cards line up even when an
            // entry has no year/publisher (e.g. arcade).
            HStack(spacing: 6) {
                if let year = entry.year, !year.isEmpty {
                    Text(year)
                }
                if let pub = entry.publisher, !pub.isEmpty {
                    Text("· \(pub)").lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(minHeight: 14, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(entry.owned ? 1.0 : 0.45)
        .help("\(entry.displayName) — \(entry.shortName)\(entry.owned ? "" : " (missing)")")
    }

    private func preferredImage() -> NSImage? {
        switch mediaKind {
        case .coverArt:
            if let coverURL, let img = NSImage(contentsOf: coverURL) { return img }
            if let snapURL, let img = NSImage(contentsOf: snapURL) { return img }
        case .snap:
            if let snapURL, let img = NSImage(contentsOf: snapURL) { return img }
            if let coverURL, let img = NSImage(contentsOf: coverURL) { return img }
        }
        return nil
    }
}
