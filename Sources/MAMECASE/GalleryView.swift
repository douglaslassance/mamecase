import SwiftUI
import AppKit

struct GalleryView: View {
    @EnvironmentObject var library: Library
    let system: SystemNode
    let hideMissing: Bool
    let showFavoritesOnly: Bool
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
        var all = library.entries(for: system, hideMissing: hideMissing)
        if showFavoritesOnly {
            let favs = library.favorites
            all = all.filter { favs.contains($0.id) }
        }
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
                              favorite: library.favorites.contains(entry.id),
                              generation: library.mediaGeneration,
                              showSystemLabel: system.kind.isCrossSystem)
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: TileFramesKey.self,
                                value: [entry.id: geo.frame(in: .named("gallery"))]
                            )
                        })
                        .contentShape(Rectangle())
                        .overlay(
                            MouseEventView(
                                onClick: { clickCount, flags in
                                    if clickCount >= 2 {
                                        library.launch(entry)
                                    } else {
                                        handleClick(entry, flags: flags)
                                    }
                                },
                                onRightClick: {
                                    // Right-click on an unselected tile makes
                                    // it the sole selection before SwiftUI's
                                    // context menu builds its items.
                                    if !selection.contains(entry.id) {
                                        selection = [entry.id]
                                        anchor = entry.id
                                    }
                                }
                            )
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
                            Button(favoriteMenuTitle(for: entry)) {
                                toggleFavorite(triggeredBy: entry)
                            }
                            Button(downloadMediaMenuTitle(for: entry)) {
                                Task {
                                    let ids = batchIDs(triggeredBy: entry)
                                    await library.downloadMedia(ids: ids, in: system)
                                }
                            }
                            .disabled(library.config == nil)
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
                                Divider()
                                if case .arcade = entry.kind {
                                    Button("Open in Arcade Database") {
                                        openSearch(for: entry, on: .arcadeDatabase)
                                    }
                                }
                                Button("Search on eBay") {
                                    openSearch(for: entry, on: .eBay)
                                }
                            }
                        }
                }
            }
            .padding(16)
            .background(
                GalleryBackgroundView(
                    onClick: { selection.removeAll() },
                    onDragChanged: { start, current, flags in
                        if marqueeStart == nil {
                            marqueeStart = start
                            marqueeAdditive = flags.contains(.command)
                            marqueeBase = marqueeAdditive ? selection : []
                        }
                        marqueeCurrent = current
                        updateMarqueeSelection()
                    },
                    onDragEnded: {
                        marqueeStart = nil
                        marqueeCurrent = nil
                        marqueeBase = []
                        marqueeAdditive = false
                    }
                )
            )
        }
        .coordinateSpace(name: "gallery")
        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
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

    private func downloadMediaMenuTitle(for entry: Entry) -> String {
        let count = (selection.contains(entry.id) && selection.count > 1) ? selection.count : 1
        return count > 1 ? "Download Media for \(count) Entries" : "Download Media"
    }

    /// IDs the context-menu batch action should target: the multi-selection
    /// if the right-clicked entry is part of it, otherwise just the entry
    /// itself.
    private func batchIDs(triggeredBy entry: Entry) -> Set<Entry.ID> {
        if selection.contains(entry.id), selection.count > 1 { return selection }
        return [entry.id]
    }

    /// "Add to Favorites" / "Remove from Favorites", swapping based on
    /// whether the right-clicked entry (or all selected) are favourite.
    private func favoriteMenuTitle(for entry: Entry) -> String {
        let targets = batchTargets(triggeredBy: entry)
        let allFavorited = targets.allSatisfy { library.favorites.contains($0.id) }
        let n = targets.count
        if n > 1 {
            return allFavorited ? "Remove \(n) from Favorites" : "Add \(n) to Favorites"
        }
        return library.favorites.contains(entry.id) ? "Remove from Favorites" : "Add to Favorites"
    }

    private func toggleFavorite(triggeredBy entry: Entry) {
        let targets = batchTargets(triggeredBy: entry)
        let ids = Set(targets.map(\.id))
        let allFavorited = targets.allSatisfy { library.favorites.contains($0.id) }
        library.setFavorite(!allFavorited, ids: ids)
    }

    /// Returns the entries a context-menu action should act on: the
    /// right-clicked entry alone, or all selected entries when the
    /// right-clicked one is part of a multi-selection.
    private func batchTargets(triggeredBy entry: Entry) -> [Entry] {
        if selection.contains(entry.id), selection.count > 1 {
            return library.entries(for: system, hideMissing: false)
                .filter { selection.contains($0.id) }
        }
        return [entry]
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
        let scheme = UserDefaults.standard.string(forKey: "controllerScheme") ?? ""
        let shader = UserDefaults.standard.string(forKey: "shaderScheme") ?? ""
        let args = MameLauncher.arguments(for: entry,
                                          romPaths: cfg.romPaths,
                                          controllerScheme: scheme,
                                          shader: shader)
        let parts = [cfg.executable] + args
        return parts.map(shellQuote).joined(separator: " ")
    }

    private enum SearchTarget {
        /// arcade-database.com lookup by MAME short name (arcade only).
        case arcadeDatabase
        /// eBay free-text search by cleaned display name.
        case eBay

        func url(for entry: Entry) -> URL? {
            switch self {
            case .arcadeDatabase:
                guard let encoded = entry.shortName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                    return nil
                }
                return URL(string: "https://adb.arcadeitalia.net/dettaglio_mame.php?game_name=\(encoded)")
            case .eBay:
                let query = DisplayName.format(entry.displayName).name
                guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                    return nil
                }
                return URL(string: "https://www.ebay.com/sch/i.html?_nkw=\(encoded)")
            }
        }
    }

    private func openSearch(for entry: Entry, on target: SearchTarget) {
        if let url = target.url(for: entry) {
            NSWorkspace.shared.open(url)
        }
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
        case .cross(let scope):
            switch scope {
            case .all: return "No entries found."
            case .recent: return "No recently launched games yet."
            case .playlist: return "Add games to this playlist from the gallery."
            }
        }
    }

    // MARK: - Selection

    // MARK: - Marquee selection

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
    let favorite: Bool
    let generation: Int
    /// Whether to display the originating system on the meta row. Only
    /// useful in cross-system views (All / Recent / Playlists) where the
    /// gallery contains entries from multiple systems.
    let showSystemLabel: Bool

    @AppStorage("mediaKind") private var mediaKind: MediaKind = .coverArt
    @State private var snapURL: URL?
    @State private var coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                    if let image = preferredImage() {
                        // Pin the image's frame to the GeometryReader's
                        // size so a wide screenshot can't push the tile
                        // out of its aspect ratio. `.clipped()` enforces
                        // the boundary.
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        Image(systemName: "gamecontroller.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
                    if favorite {
                        Image(systemName: "star.fill")
                            .font(.callout)
                            .foregroundStyle(.yellow)
                            .padding(4)
                            .background(.thinMaterial, in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(6)
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
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(tileAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Line 1: just the cleaned title.
            let formatted = DisplayName.format(entry.displayName)
            Text(formatted.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

            // Line 2: region flag, year, publisher (space-separated, no
            // dot separators). Always reserve the row so cards line up.
            HStack(spacing: 6) {
                if !formatted.flags.isEmpty {
                    Text(formatted.flags)
                }
                if let year = entry.year, !year.isEmpty {
                    Text(year)
                }
                if let pub = entry.publisher, !pub.isEmpty {
                    Text(pub).lineLimit(1).truncationMode(.tail)
                }
                if showSystemLabel, let sys = systemLabel {
                    Text(sys).lineLimit(1).truncationMode(.tail)
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
        .task(id: "\(entry.id)/\(generation)/\(mediaKind.rawValue)") {
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
        // Only auto-fetch online media for ROMs the user actually owns.
        // For unowned entries the menu's "Download Media" action is the
        // explicit, user-driven way to populate art.
        guard entry.owned else { return }

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
        let url: URL? = (mediaKind == .coverArt) ? coverURL : snapURL
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Short human label of the system this entry belongs to, for the
    /// cross-system views (All/Recent/Playlist). Returns nil when the
    /// caller said not to show one.
    private var systemLabel: String? {
        switch entry.kind {
        case .arcade: return "Arcade"
        case .software(let sys): return library.softwareListDisplayName(for: sys) ?? sys
        }
    }

    /// Aspect ratio for the artwork tile, picked per-kind and per-system
    /// so e.g. Game Boy snaps aren't forced into a landscape frame and
    /// jewel-case PS1 covers aren't squashed into the same shape as
    /// Famicom boxes.
    private var tileAspectRatio: CGFloat {
        switch mediaKind {
        case .coverArt: return CoverArtAspectRatio.ratio(for: entry)
        case .snap: return SnapAspectRatio.ratio(for: entry)
        }
    }
}
