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
    @State private var tileFrames: [Entry.ID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBase: Set<Entry.ID> = []
    @State private var marqueeAdditive: Bool = false
    @FocusState private var focused: Bool

    private var marqueeRect: CGRect? {
        guard let a = marqueeStart, let b = marqueeCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: gridItemSize, maximum: gridItemSize * 1.4), spacing: 16)]
    }

    private var entries: [Entry] {
        let all = library.entries(for: system, hideMissing: hideMissing)
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        // Lazy/fuzzy match: every whitespace-separated token in the query
        // must appear (case-insensitively) somewhere in the entry's
        // searchable fields. So `Spo cl` matches `Capcom Sports Club`.
        let tokens = trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return all.filter { entry in
            var haystack = "\(entry.displayName) \(entry.shortName)"
            if let y = entry.year { haystack += " \(y)" }
            if let p = entry.publisher { haystack += " \(p)" }
            let lower = haystack.lowercased()
            return tokens.allSatisfy { lower.contains($0) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(entries) { entry in
                    EntryTile(entry: entry,
                              status: library.verifications[entry.id],
                              verifying: library.verifyingIDs.contains(entry.id),
                              selected: selection.contains(entry.id),
                              generation: library.mediaGeneration)
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: TileFramesKey.self,
                                value: [entry.id: geo.frame(in: .named("gallery"))]
                            )
                        })
                        .contentShape(Rectangle())
                        .overlay(
                            MouseEventView { clickCount, flags in
                                if clickCount >= 2 {
                                    library.launch(entry)
                                } else {
                                    handleClick(entry, flags: flags)
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
                            Button(regenerateMenuTitle(for: entry)) {
                                Task {
                                    if selection.contains(entry.id), selection.count > 1 {
                                        await library.regenerateMedia(ids: selection, in: system)
                                    } else {
                                        await library.regenerateMedia(ids: [entry.id], in: system)
                                    }
                                }
                            }
                            .disabled(library.config == nil)
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
        .coordinateSpace(name: "gallery")
        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection.removeAll() }
        )
        .gesture(marqueeGesture)
        .overlay(alignment: .topLeading) {
            if let rect = marqueeRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(
                        Rectangle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
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

    private func regenerateMenuTitle(for entry: Entry) -> String {
        let count = (selection.contains(entry.id) && selection.count > 1) ? selection.count : 1
        return count > 1 ? "Regenerate Media for \(count) Entries" : "Regenerate Media"
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

    // MARK: - Marquee selection

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("gallery"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeAdditive = NSEvent.modifierFlags.contains(.command)
                    marqueeBase = marqueeAdditive ? selection : []
                }
                marqueeCurrent = value.location
                updateMarqueeSelection()
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBase = []
                marqueeAdditive = false
            }
    }

    private func updateMarqueeSelection() {
        guard let rect = marqueeRect else { return }
        var result = marqueeBase
        for (id, frame) in tileFrames where frame.intersects(rect) {
            if marqueeAdditive, marqueeBase.contains(id) {
                result.remove(id)
            } else {
                result.insert(id)
            }
        }
        if result != selection { selection = result }
    }

    private func handleClick(_ entry: Entry, flags: NSEvent.ModifierFlags) {
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

/// Collects each visible tile's frame in the gallery coordinate space so
/// the marquee can compute intersection-based selection.
struct TileFramesKey: PreferenceKey {
    static var defaultValue: [Entry.ID: CGRect] = [:]
    static func reduce(value: inout [Entry.ID: CGRect],
                       nextValue: () -> [Entry.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct EntryTile: View {
    @EnvironmentObject var library: Library
    let entry: Entry
    let status: RomStatus?
    let verifying: Bool
    let selected: Bool
    let generation: Int

    @AppStorage("mediaKind") private var mediaKind: MediaKind = .coverArt
    @State private var snapURL: URL?
    @State private var coverURL: URL?

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
        .task(id: "\(entry.id)/\(generation)") {
            await resolveMedia()
        }
    }

    /// Resolution chain runs against Library:
    ///   1. Local file (loose or archive-extracted) via `mediaURL`
    ///   2. Online fetch via `fetchOnlineMedia` (libretro for arcade)
    /// Each step writes into the media cache on success, so step 1's
    /// follow-up read finds the file.
    private func resolveMedia() async {
        snapURL = library.mediaURL(for: entry, kind: .snap)
        coverURL = library.mediaURL(for: entry, kind: .coverArt)
        guard snapURL == nil && coverURL == nil else { return }

        // Prefer the kind the user is viewing; fall back to the other one
        // so cross-fallback still works.
        let order: [MediaKind] = mediaKind == .snap ? [.snap, .coverArt] : [.coverArt, .snap]
        for kind in order {
            if await library.fetchOnlineMedia(for: entry, kind: kind) != nil { break }
        }
        snapURL = library.mediaURL(for: entry, kind: .snap)
        coverURL = library.mediaURL(for: entry, kind: .coverArt)
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
