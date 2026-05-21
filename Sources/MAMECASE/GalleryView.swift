import SwiftUI
import AppKit

struct GalleryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var imageSizes = ImageSizeCache.shared
    let system: SystemNode
    let hideMissing: Bool
    let showFavoritesOnly: Bool
    let showFailingOnly: Bool
    let regionFilter: RegionFilter
    let layoutMode: LayoutMode
    @Binding var searchText: String
    @Binding var selection: Set<Entry.ID>

    @AppStorage("gridItemSize") private var gridItemSize: Double = 180
    @AppStorage("itemSpacing") private var itemSpacing: Double = 16
    @State private var anchor: Entry.ID?
    @State private var pendingDownload: PendingDownload?
    @State private var pendingDelete: PendingDelete?
    @State private var tileFrames: [Entry.ID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBase: Set<Entry.ID> = []
    @State private var marqueeAdditive: Bool = false
    @State private var containerWidth: CGFloat = 0
    @FocusState private var focused: Bool

    private var marqueeRect: CGRect? {
        guard let a = marqueeStart, let b = marqueeCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private var entries: [Entry] {
        var all = library.entries(for: system, hideMissing: hideMissing)
        if showFavoritesOnly {
            let favs = library.favorites
            all = all.filter { favs.contains($0.id) }
        }
        if showFailingOnly {
            let v = library.verifications
            all = all.filter { entry in
                guard let s = v[entry.id] else { return false }
                return s.isFailing
            }
        }
        if regionFilter != .all {
            all = all.filter { regionFilter.matches($0.displayName) }
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
        // GeometryReader wraps the ScrollView (not its content) so width
        // updates during AppKit live-resize. Inside the ScrollView a
        // GeometryReader-as-content would collapse the scroll height,
        // and `.background(GeometryReader)` only republishes after the
        // resize ends — Peel uses the same outer-GeometryReader idiom.
        GeometryReader { geo in
            ScrollView {
                galleryContent(containerWidth: geo.size.width)
            }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
            .onAppear { containerWidth = geo.size.width }
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
        // ⌘A / ⌃A → select every entry the current filter+search show.
        .onKeyPress(KeyEquivalent("a")) {
            let mods = NSEvent.modifierFlags
            guard mods.contains(.command) || mods.contains(.control) else {
                return .ignored
            }
            selection = Set(entries.map(\.id))
            anchor = entries.first?.id
            return .handled
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
        .alert("Delete ROMs?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                let targets = pendingDelete?.targets ?? []
                pendingDelete = nil
                let ids = Set(targets.map(\.id))
                _ = library.deleteROMs(ids: ids, in: system)
                selection.subtract(ids)
            }
        } message: {
            if let p = pendingDelete {
                if p.targets.count == 1 {
                    Text("Permanently delete \(p.targets[0].shortName)?")
                } else {
                    Text("Permanently delete \(p.targets.count) ROMs?")
                }
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

    @ViewBuilder
    private func galleryContent(containerWidth: CGFloat) -> some View {
        let pad = CGFloat(itemSpacing)
        let inner = max(0, containerWidth - pad * 2)
        VStack(alignment: .leading, spacing: 0) {
            switch layoutMode {
            case .verticalMasonry:
                VerticalMasonryView(
                    entries: entries,
                    containerWidth: inner,
                    targetColumnWidth: gridItemSize,
                    spacing: pad,
                    aspectRatio: { artworkAspect(for: $0) }
                ) { entry, artworkSize in
                    tileView(for: entry, fixedSize: artworkSize)
                }
            case .horizontalMasonry:
                HorizontalMasonryView(
                    entries: entries,
                    containerWidth: inner,
                    targetRowHeight: gridItemSize,
                    spacing: pad,
                    aspectRatio: { artworkAspect(for: $0) }
                ) { entry, artworkSize in
                    tileView(for: entry, fixedSize: artworkSize)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(pad)
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

    /// Per-entry aspect ratio (width / height) used by masonry layouts.
    /// Resolution order:
    ///   1. real natural ratio from `ImageSizeCache` (loaded asynchronously)
    ///   2. square (1.0) when there's no media URL at all, or when we
    ///      tried to measure one and failed (corrupt / zero-byte file) —
    ///      the gamepad placeholder should always render in a uniform
    ///      box rather than inherit a portrait per-system shape.
    ///   3. per-system convention while we wait for the size to stream in.
    private func artworkAspect(for entry: Entry) -> CGFloat {
        let url = library.mediaURL(for: entry, kind: entryMediaPreference)
        guard let url else { return 1.0 }
        if let size = imageSizes.size(for: url), size.height > 0 {
            return size.width / size.height
        }
        if imageSizes.didFail(url) { return 1.0 }
        switch entry.kind {
        case .arcade: return SnapAspectRatio.ratio(for: entry)
        case .software:
            switch entryMediaPreference {
            case .flyers: return FlyerAspectRatio.ratio(for: entry)
            case .snap: return SnapAspectRatio.ratio(for: entry)
            }
        }
    }

    @AppStorage("mediaKind") private var entryMediaPreference: MediaKind = .flyers

    @ViewBuilder
    private func tileView(for entry: Entry, fixedSize: CGSize?) -> some View {
        EntryTile(entry: entry,
                  selected: selection.contains(entry.id),
                  favorite: library.favorites.contains(entry.id),
                  generation: library.mediaGeneration,
                  showSystemLabel: system.kind.isCrossSystem,
                  fixedArtworkSize: fixedSize)
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
                        if !selection.contains(entry.id) {
                            selection = [entry.id]
                            anchor = entry.id
                        }
                    }
                )
            )
            // Verification spinner / badge sits ABOVE MouseEventView so
            // clicks on the badge open the popover instead of being
            // swallowed by the NSView-backed click capture below.
            .overlay(alignment: .topTrailing) {
                tileBadge(for: entry)
                    // 8pt tile padding + 6pt inner badge padding =
                    // matches where the badge used to live when it was
                    // anchored to the artwork's GeometryReader.
                    .padding(14)
            }
            .contextMenu { tileContextMenu(for: entry) }
    }

    /// Top-right corner overlay: progress spinner while verifying, or
    /// the clickable status badge when the latest audit flagged the ROM
    /// as bad / best-available / error.
    @ViewBuilder
    private func tileBadge(for entry: Entry) -> some View {
        if library.verifyingIDs.contains(entry.id) {
            // Match VerificationBadge's chrome (4pt padding + thinMaterial
            // circle) so the spinner-to-badge swap doesn't visibly resize.
            ProgressView()
                .controlSize(.small)
                .padding(4)
                .background(.thinMaterial, in: Circle())
        } else if let status = library.verifications[entry.id], status.isFailing {
            VerificationBadge(status: status,
                              details: library.verificationDetails[entry.id])
        }
    }

    @ViewBuilder
    private func tileContextMenu(for entry: Entry) -> some View {
        // Group 1: launch + verify.
        Button {
            if selection.contains(entry.id), selection.count > 1 {
                library.launch(ids: selection, in: system)
            } else {
                library.launch(entry)
            }
        } label: { Label("Launch", systemImage: "play.fill") }
        Button {
            Task {
                if selection.contains(entry.id), selection.count > 1 {
                    await library.verify(ids: selection, in: system)
                } else {
                    await library.verify(entry)
                }
            }
        } label: { Label(verifyMenuTitle(for: entry), systemImage: "checkmark.seal") }
        .disabled(library.config == nil)
        Button {
            library.rescanPresence(ids: batchIDs(triggeredBy: entry), in: system)
        } label: { Label(rescanMenuTitle(for: entry), systemImage: "arrow.clockwise.circle") }
        .disabled(library.config == nil)

        Divider()

        // Group 2: favourite + playlists.
        Button {
            toggleFavorite(triggeredBy: entry)
        } label: { Label(favoriteMenuTitle(for: entry), systemImage: favoriteMenuSymbol(for: entry)) }
        Menu {
            ForEach(library.playlists) { p in
                Button(p.name) {
                    library.addToPlaylist(p.id, entryIDs: batchIDs(triggeredBy: entry))
                }
            }
            if !library.playlists.isEmpty { Divider() }
            Button {
                let p = library.createPlaylist(named: "New Playlist")
                library.addToPlaylist(p.id, entryIDs: batchIDs(triggeredBy: entry))
            } label: { Label("New Playlist…", systemImage: "plus") }
        } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
        if case .cross(let scope) = system.kind,
           case .playlist(let pid) = scope {
            Button {
                library.removeFromPlaylist(pid, entryIDs: batchIDs(triggeredBy: entry))
            } label: { Label("Remove from Playlist", systemImage: "minus.circle") }
        }

        Divider()

        // Group 3: media + ROM downloads. "Download ROM" only renders
        // when the user has configured a Base URL in Settings.
        if case .arcade = entry.kind, romDownloadConfigured {
            Button {
                startDownload(triggeredBy: entry)
            } label: { Label(downloadMenuTitle(for: entry), systemImage: "arrow.down.circle") }
            .disabled(library.config == nil)
        }
        Button {
            Task {
                let ids = batchIDs(triggeredBy: entry)
                await library.updateMedia(ids: ids, in: system)
            }
        } label: { Label(updateMediaMenuTitle(for: entry), systemImage: "photo.badge.arrow.down") }
        .disabled(library.config == nil)

        Divider()

        // Group 4: reveal + copy (single-entry only).
        if !isMultiSelected(entry) {
            if let rom = romFileURL(for: entry) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([rom])
                } label: { Label("Reveal ROM in Finder", systemImage: "magnifyingglass") }
            }
            if let snap = library.mediaURL(for: entry, kind: .snap) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([snap])
                } label: { Label("Reveal Snapshot in Finder", systemImage: "magnifyingglass") }
            }
            Button {
                copyToPasteboard(entry.shortName)
            } label: { Label("Copy ROM Name", systemImage: "doc.on.doc") }
            Button {
                copyToPasteboard(launchCommand(for: entry))
            } label: { Label("Copy Launch Command", systemImage: "terminal") }
            .disabled(library.config == nil)

            Divider()

            // Group 5: external lookups.
            if case .arcade = entry.kind {
                Button {
                    openSearch(for: entry, on: .arcadeDatabase)
                } label: { Label("Open in Arcade Database", systemImage: "safari") }
            }
            Button {
                openSearch(for: entry, on: .eBay)
            } label: { Label("Search on eBay", systemImage: "magnifyingglass.circle") }

            Divider()
        }

        // Group 6: destructive.
        Button(role: .destructive) {
            let targets = library
                .entries(for: system, hideMissing: false)
                .filter { batchIDs(triggeredBy: entry).contains($0.id) }
                .filter(\.owned)
            guard !targets.isEmpty else { return }
            pendingDelete = PendingDelete(targets: targets)
        } label: { Label(deleteMenuTitle(for: entry), systemImage: "trash") }
        .disabled(library.config == nil)
    }

    /// Symbol matching the favourite toggle's current effect — filled
    /// star when we'd be adding to favourites, slashed star when removing.
    private func favoriteMenuSymbol(for entry: Entry) -> String {
        let targets = batchTargets(triggeredBy: entry)
        let allFavorited = targets.allSatisfy { library.favorites.contains($0.id) }
        return allFavorited ? "star.slash" : "star"
    }

    private func verifyMenuTitle(for entry: Entry) -> String {
        isMultiSelected(entry) ? "Verify ROMs" : "Verify ROM"
    }

    /// Singular vs plural label for the "Rescan ROM File(s)" entry.
    private func rescanMenuTitle(for entry: Entry) -> String {
        isMultiSelected(entry) ? "Rescan ROM Files" : "Rescan ROM File"
    }

    private func downloadMenuTitle(for entry: Entry) -> String {
        downloadTargets(triggeredBy: entry).count > 1 ? "Download ROMs" : "Download ROM"
    }

    /// "Update Media" — same label in singular and plural, no count.
    private func updateMediaMenuTitle(for entry: Entry) -> String {
        "Update Media"
    }

    /// "Delete ROM" / "Delete ROMs". Always destructive — only enabled
    /// when at least one target actually has a file on disk.
    private func deleteMenuTitle(for entry: Entry) -> String {
        isMultiSelected(entry) ? "Delete ROMs" : "Delete ROM"
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
        return allFavorited ? "Remove from Favorites" : "Add to Favorites"
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

    /// True when both prerequisites for "Download ROM" are satisfied:
    /// the user configured a Base URL in Settings AND there's at least
    /// one writable directory in mame.ini's rompath where the download
    /// can land. We hide the menu item rather than show-then-refuse.
    private var romDownloadConfigured: Bool {
        let urlSet = !settings.romDownloadBaseURL
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
        guard urlSet else { return false }
        guard let cfg = library.config else { return false }
        let fm = FileManager.default
        return cfg.romPaths.contains { dir in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir.path, isDirectory: &isDir)
                && isDir.boolValue
                && fm.isWritableFile(atPath: dir.path)
        }
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

    /// Resolved on-disk URL for an entry's ROM, or nil if it's not
    /// present. Handles all four MAME layouts (zip / 7z / chd / subdir)
    /// via `VerificationCache.romFile`.
    private func romFileURL(for entry: Entry) -> URL? {
        guard let cfg = library.config else { return nil }
        return VerificationCache.romFile(for: entry, in: cfg.romPaths)
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
                                          statePath: cfg.statePath,
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

/// Top-right corner badge surfacing a failing verification verdict.
/// Click opens a popover with MAME's per-file diagnostics. Lives at the
/// tile level (overlaid above the `MouseEventView` click capture) so
/// clicks reach the button instead of being eaten by AppKit.
private struct VerificationBadge: View {
    let status: RomStatus
    let details: String?
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: status.systemImage)
                .font(.callout)
                .foregroundStyle(status.tint)
                .padding(4)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help("ROM status: \(status.label) — click for details")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.tint)
                    Text(status.label)
                        .font(.headline)
                }
                Text(statusExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // Without this the popover gives Text a one-line
                    // budget and ellipsis-truncates instead of wrapping.
                    .fixedSize(horizontal: false, vertical: true)
                if let d = details, !d.isEmpty {
                    Divider()
                    Text(d)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 360, alignment: .leading)
        }
    }

    /// One-line plain-English explanation of what the verdict means.
    /// Verbatim from `RomStatus`'s doc comments so the popover stays in
    /// sync with the colour scheme.
    private var statusExplanation: String {
        switch status {
        case .bad:
            return "Missing critical files or wrong checksums. The ROM likely won't run correctly."
        case .bestAvailable:
            return "Playable, but some optional files are missing or have wrong CRCs."
        case .error:
            return "Audit ran but MAME's output couldn't be parsed (or the process failed)."
        case .good, .notFound:
            return ""
        }
    }
}

/// Picks between aspect-ratio sizing (grid) and explicit-size sizing
/// (masonry). Used by `EntryTile`'s artwork block.
private struct ArtworkSizing: ViewModifier {
    let aspect: CGFloat
    let fixedSize: CGSize?

    func body(content: Content) -> some View {
        if let s = fixedSize {
            content.frame(width: s.width, height: s.height)
        } else {
            content.aspectRatio(aspect, contentMode: .fit)
        }
    }
}

/// Tracks a pending download awaiting overwrite confirmation.
struct PendingDownload {
    let targets: [Entry]
    let existing: [Entry]
}

/// Tracks a pending destructive ROM delete awaiting user confirmation.
struct PendingDelete {
    let targets: [Entry]
}

/// Carries the gallery ScrollView's content width up to the GalleryView
/// state so masonry layouts can flow without using GeometryReader as a
/// container (which collapses ScrollView height and breaks scrolling).
struct GalleryWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
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
    let selected: Bool
    let favorite: Bool
    let generation: Int
    /// Whether to display the originating system on the meta row. Only
    /// useful in cross-system views (All / Recent / Playlists) where the
    /// gallery contains entries from multiple systems.
    let showSystemLabel: Bool
    /// When set, the artwork frame is pinned to this size rather than
    /// derived from `tileAspectRatio` — used by the masonry layouts that
    /// pre-compute each tile's frame.
    var fixedArtworkSize: CGSize? = nil

    @AppStorage("mediaKind") private var mediaKind: MediaKind = .flyers
    @AppStorage("tileCornerRadius") private var tileCornerRadius: Double = 10
    @State private var snapURL: URL?
    @State private var coverURL: URL?

    /// Corner radius applied to the inner artwork — slightly tighter than
    /// the tile chrome so the artwork looks nested inside it. Clamps to 0.
    private var artworkCornerRadius: CGFloat {
        max(0, CGFloat(tileCornerRadius) - 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: artworkCornerRadius)
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
                    // NOTE: the verification spinner / status badge
                    // lives in the outer GalleryView overlay so it can
                    // sit ABOVE MouseEventView and receive clicks for
                    // the details popover.
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .modifier(ArtworkSizing(aspect: tileAspectRatio, fixedSize: fixedArtworkSize))
            .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius))

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
        // When the parent masonry pins the artwork to a specific width
        // (horizontal layout in particular), constrain the entire tile so
        // its title/meta rows don't stretch the chrome wider than the
        // artwork. The +16 matches `TileChrome.horizontal` (8pt padding
        // on each side).
        .frame(width: fixedArtworkSize.map { $0.width + 16 })
        .background(
            RoundedRectangle(cornerRadius: CGFloat(tileCornerRadius))
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .background(RoundedRectangle(cornerRadius: CGFloat(tileCornerRadius)).fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(tileCornerRadius))
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
        coverURL = library.mediaURL(for: entry, kind: .flyers)
        guard snapURL == nil && coverURL == nil else { return }
        // Only auto-fetch online media for ROMs the user actually owns.
        // For unowned entries the menu's "Download Media" action is the
        // explicit, user-driven way to populate art.
        guard entry.owned else { return }

        // Prefer the kind the user is viewing; fall back to the other one
        // so cross-fallback still works.
        let order: [MediaKind] = mediaKind == .snap ? [.snap, .flyers] : [.flyers, .snap]
        for kind in order {
            if await library.fetchOnlineMedia(for: entry, kind: kind) != nil { break }
        }
        snapURL = library.mediaURL(for: entry, kind: .snap)
        coverURL = library.mediaURL(for: entry, kind: .flyers)
    }

    private func preferredImage() -> NSImage? {
        let url: URL? = (mediaKind == .flyers) ? coverURL : snapURL
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
        case .flyers: return FlyerAspectRatio.ratio(for: entry)
        case .snap: return SnapAspectRatio.ratio(for: entry)
        }
    }
}
