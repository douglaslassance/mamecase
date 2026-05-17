import SwiftUI
import AppKit

struct GalleryView: View {
    @EnvironmentObject var library: Library
    let system: SystemNode
    let hideMissing: Bool
    @Binding var searchText: String
    @Binding var selection: Set<Entry.ID>

    @AppStorage("gridItemSize") private var gridItemSize: Double = 180
    @State private var anchor: Entry.ID?
    @State private var pendingDownload: PendingDownload?
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
                              status: library.verifications[entry.id],
                              verifying: library.verifyingIDs.contains(entry.id),
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
                            Button(verifyMenuTitle(for: entry)) {
                                Task {
                                    if selection.contains(entry.id), selection.count > 1 {
                                        await library.verify(ids: selection, in: system)
                                    } else {
                                        await library.verify(entry)
                                    }
                                }
                            }
                            .disabled(library.config == nil)
                            if case .arcade = entry.kind {
                                Button(downloadMenuTitle(for: entry)) {
                                    startDownload(triggeredBy: entry)
                                }
                                .disabled(library.config == nil)
                            }
                            if !isMultiSelected(entry) {
                                Divider()
                                if let snap = library.mediaURL(for: entry, kind: .snap) {
                                    Button("Reveal Snapshot in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([snap])
                                    }
                                }
                                Button("Copy ROM Name") {
                                    copyToPasteboard(entry.shortName)
                                }
                                Button("Copy Launch Command") {
                                    copyToPasteboard(launchCommand(for: entry))
                                }
                                .disabled(library.config == nil)
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
        .alert("Overwrite existing ROMs?",
               isPresented: Binding(get: { pendingDownload != nil },
                                    set: { if !$0 { pendingDownload = nil } })) {
            Button("Cancel", role: .cancel) { pendingDownload = nil }
            if let p = pendingDownload, p.existing.count < p.targets.count {
                Button("Skip Existing") {
                    let new = p.targets.filter { e in !p.existing.contains(where: { $0.id == e.id }) }
                    pendingDownload = nil
                    Task { await library.download(entries: new, overwrite: true) }
                }
            }
            Button("Overwrite", role: .destructive) {
                let targets = pendingDownload?.targets ?? []
                pendingDownload = nil
                Task { await library.download(entries: targets, overwrite: true) }
            }
        } message: {
            if let p = pendingDownload {
                Text(overwriteMessage(for: p))
            }
        }
    }

    private func verifyMenuTitle(for entry: Entry) -> String {
        let count = (selection.contains(entry.id) && selection.count > 1) ? selection.count : 1
        return count > 1 ? "Verify \(count) ROMs" : "Verify ROM"
    }

    private func downloadMenuTitle(for entry: Entry) -> String {
        let targets = downloadTargets(triggeredBy: entry)
        return targets.count > 1 ? "Download \(targets.count) ROMs" : "Download ROM"
    }

    /// Compute the entries that a context-menu action should act on:
    /// the right-clicked entry, or every selected entry if it's part of
    /// a multi-selection.
    private func downloadTargets(triggeredBy entry: Entry) -> [Entry] {
        if selection.contains(entry.id), selection.count > 1 {
            return library.entries(for: system, hideMissing: false)
                .filter { selection.contains($0.id) && isArcade($0) }
        }
        return isArcade(entry) ? [entry] : []
    }

    private func isArcade(_ entry: Entry) -> Bool {
        if case .arcade = entry.kind { return true }
        return false
    }

    private func startDownload(triggeredBy entry: Entry) {
        let targets = downloadTargets(triggeredBy: entry)
        guard !targets.isEmpty else { return }
        let existing = targets.filter(\.owned)
        if existing.isEmpty {
            Task { await library.download(entries: targets, overwrite: true) }
        } else {
            pendingDownload = PendingDownload(targets: targets, existing: existing)
        }
    }

    private func overwriteMessage(for p: PendingDownload) -> String {
        if p.targets.count == 1 {
            return "\(p.targets[0].shortName).zip already exists in your rompath."
        }
        return "\(p.existing.count) of \(p.targets.count) ROMs already exist in your rompath."
    }

    private func isMultiSelected(_ entry: Entry) -> Bool {
        selection.contains(entry.id) && selection.count > 1
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Build the shell-quoted command line we'd execute to launch this
    /// entry — mirrors what `Library.launch(_:)` actually runs.
    private func launchCommand(for entry: Entry) -> String {
        guard let cfg = library.config else { return entry.shortName }
        let systemID = ControllerSchemes.systemID(for: entry)
        let scheme = ControllerSchemes.scheme(for: systemID)
        let shader = ShaderSchemes.scheme(for: systemID)
        let args = MameLauncher.arguments(for: entry,
                                          romPaths: cfg.romPaths,
                                          controllerScheme: scheme,
                                          shader: shader)
        let parts = [cfg.executable] + args
        return parts.map(shellQuote).joined(separator: " ")
    }

    private func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.:=,@%+")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return s
        }
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
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

/// Tracks a pending download awaiting overwrite confirmation.
struct PendingDownload {
    let targets: [Entry]
    let existing: [Entry]
}

private struct EntryTile: View {
    let entry: Entry
    let snapURL: URL?
    let coverURL: URL?
    let status: RomStatus?
    let verifying: Bool
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
                if verifying {
                    ProgressView()
                        .controlSize(.small)
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                } else if let status {
                    Image(systemName: status.systemImage)
                        .font(.callout)
                        .foregroundStyle(status.tint)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                        .help("ROM status: \(status.label)")
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
