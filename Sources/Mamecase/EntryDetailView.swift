import SwiftUI
import AppKit

/// Full-size detail card for a single entry: the artwork at a size worth
/// looking at on the left, metadata plus the HISTORY text on the right.
///
/// Opened from the gallery with Space (Quick Look idiom), ⌘I, or the
/// tile's context menu. ←/→ page through the gallery's *filtered* entry
/// list, so the card only ever walks what the user can see behind it.
///
/// Presented by `EntryDetailOverlay`, not as a sheet — see there.
struct EntryDetailView: View {
    @EnvironmentObject var library: Library

    /// System the gallery is showing. Only needed so "Download Media"
    /// can route through `Library.updateMedia(ids:in:)`.
    let system: SystemNode
    /// The gallery's currently visible entries, in display order.
    let entries: [Entry]
    /// Which of them the card is on. Bound so ←/→ moves the gallery's
    /// idea of the detailed entry too, and so setting it to nil closes.
    @Binding var entryID: Entry.ID?

    /// Seeded from the gallery's media toggle on open, then owned by the
    /// card — flipping to the screenshot here shouldn't reshuffle the
    /// masonry layout behind it.
    @AppStorage("mediaKind") private var galleryMediaKind: MediaKind = .flyers
    @State private var mediaKind: MediaKind = .flyers
    @State private var artwork: NSImage?
    @State private var loadingArtwork = false
    @State private var history: String?
    @State private var loadingHistory = false
    @FocusState private var focused: Bool

    private var entry: Entry? { entries.first { $0.id == entryID } }

    var body: some View {
        Group {
            if let entry {
                content(for: entry)
            } else {
                Color.clear
            }
        }
        // Ranges rather than a fixed size: the card is inset inside the
        // window, so on a small window it shrinks instead of clipping.
        .frame(minWidth: 700, idealWidth: 980, maxWidth: 1040,
               minHeight: 460, idealHeight: 640, maxHeight: 780)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            mediaKind = galleryMediaKind
            focused = true
        }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.return) {
            guard let entry else { return .ignored }
            library.launch(entry)
            return .handled
        }
        .task(id: entryID) {
            if let entry { syncMediaKind(for: entry) }
            await loadHistory()
        }
        .task(id: artworkToken) { await loadArtwork() }
    }

    /// Everything the decoded artwork depends on. `mediaGeneration` is in
    /// here so an "Update Media" run refreshes the open card.
    private var artworkToken: String {
        "\(entryID ?? "")/\(mediaKind.rawValue)/\(library.mediaGeneration)"
    }

    // MARK: - Layout

    @ViewBuilder
    private func content(for entry: Entry) -> some View {
        HStack(spacing: 0) {
            artworkPane(for: entry)
            Divider()
            infoPane(for: entry)
                .frame(width: 380)
        }
    }

    /// Hero pane: the art over a blurred, blown-up copy of itself. The
    /// backdrop is what gives the glass something to refract — over a
    /// flat window background it just looks like a grey pill.
    ///
    /// Backdrop and art hang off `.background` / `.overlay` of an empty
    /// spacer rather than sharing a `ZStack`, because a `scaledToFill`
    /// image in a stack grows the stack: the `scaledToFit` art then fits
    /// that oversized stack and gets clipped at the pane's real edges,
    /// margin and all. Background and overlay content is handed the
    /// parent's size and can never push back on it, so the art always
    /// fits whole.
    @ViewBuilder
    private func artworkPane(for entry: Entry) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 80, opaque: true)
                        .saturation(1.4)
                        .opacity(0.5)
                }
            }
            .overlay {
                if let artwork {
                    // Same treatment whichever media is showing: the art
                    // floats with a margin, rounded corners and a shadow,
                    // letterboxed by the backdrop wherever the aspect
                    // doesn't match the pane.
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.32), radius: 26, y: 12)
                        .padding(28)
                } else if loadingArtwork {
                    ProgressView()
                } else {
                    missingArtwork(for: entry).padding(28)
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                // Only what this entry actually has, and only when
                // there's a choice to make — a lone pill is a control
                // that does nothing.
                let kinds = availableKinds(for: entry)
                if kinds.count > 1 {
                    mediaSwitch(kinds).padding(.bottom, 18)
                }
            }
    }

    @ViewBuilder
    private func mediaSwitch(_ kinds: [MediaKind]) -> some View {
        HStack(spacing: 4) {
            ForEach(kinds) { kind in
                Button {
                    mediaKind = kind
                } label: {
                    Text(kind.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(mediaKind == kind ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background {
                            if mediaKind == kind {
                                Capsule().fill(Color.accentColor)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassCapsule()
    }

    @ViewBuilder
    private func missingArtwork(for entry: Entry) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No \(mediaKind.label.lowercased()) artwork")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Download Media") {
                Task { await library.updateMedia(ids: [entry.id], in: system) }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassCapsule()
            .disabled(library.config == nil)
        }
    }

    @ViewBuilder
    private func infoPane(for entry: Entry) -> some View {
        let formatted = FormattedDisplayName.format(entry.displayName)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(formatted.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !formatted.flags.isEmpty { Text(formatted.flags) }
                    Text(systemLabel(for: entry))
                    if let year = entry.year, !year.isEmpty { Text(year) }
                    if let pub = entry.publisher, !pub.isEmpty {
                        Text(pub).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        library.launch(entry)
                    } label: {
                        Label("Launch", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    // Standard controls, not glass. This column is an
                    // opaque panel: glass over it has nothing to refract,
                    // so `.glassProminent` renders as a flat, oddly
                    // tinted slab. Glass stays over the artwork, where
                    // there's something behind it.
                    .buttonStyle(.borderedProminent)
                    .disabled(library.config == nil)

                    Button {
                        library.toggleFavorite(entry)
                    } label: {
                        Image(systemName: isFavorite(entry) ? "star.fill" : "star")
                            .foregroundStyle(isFavorite(entry) ? Color.yellow : Color.primary)
                    }
                    .buttonStyle(.bordered)
                    .help(isFavorite(entry) ? "Remove from Favorites" : "Add to Favorites")
                }
                .padding(.top, 2)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                row("Short name", entry.shortName, monospaced: true)
                if let year = entry.year, !year.isEmpty { row("Year", year) }
                if let pub = entry.publisher, !pub.isEmpty { row("Publisher", pub) }
                romRow(for: entry)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            historyPane(for: entry)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func historyPane(for entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ScrollView {
                if loadingHistory {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if let history, !history.isEmpty {
                    Text(history)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                } else {
                    Text("No history entry for \(HistoryProvider.key(for: entry)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ROM line: the verification verdict when we have one, otherwise
    /// just whether the file is on disk.
    @ViewBuilder
    private func romRow(for entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("ROM")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            if let status = library.verifications[entry.id] {
                HStack(spacing: 4) {
                    Image(systemName: status.systemImage).foregroundStyle(status.tint)
                    Text(status.label)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(entry.owned ? "Present" : "Missing")
                    .font(.caption)
                    .foregroundStyle(entry.owned ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Data

    private func loadHistory() async {
        guard let entry else {
            history = nil
            return
        }
        history = nil
        loadingHistory = true
        history = await library.historyText(for: entry)
        loadingHistory = false
    }

    /// Decodes at detail resolution rather than reusing the tile
    /// thumbnail — the whole point of the card is a bigger image.
    private func loadArtwork() async {
        guard let entry, let url = library.mediaURL(for: entry, kind: mediaKind) else {
            artwork = nil
            loadingArtwork = false
            return
        }
        artwork = nil
        loadingArtwork = true
        artwork = await ThumbnailCache.shared.fullImage(for: url)
        loadingArtwork = false
    }

    /// Every media kind that resolves to a file for this entry, in
    /// `MediaKind` order. Purely local — the card shows what's on disk
    /// rather than firing off downloads for six kinds per entry.
    private func availableKinds(for entry: Entry) -> [MediaKind] {
        MediaKind.allCases.filter { library.mediaURL(for: entry, kind: $0) != nil }
    }

    /// Keep the card on a kind this entry actually has. The kind is
    /// carried over from the gallery (and from the previous entry while
    /// paging), so without this, walking into a game that has only a
    /// marquee would show an empty pane next to a switch offering the
    /// marquee. A kind the user picked that *does* resolve is left alone.
    private func syncMediaKind(for entry: Entry) {
        guard library.mediaURL(for: entry, kind: mediaKind) == nil,
              let first = availableKinds(for: entry).first
        else { return }
        mediaKind = first
    }

    private func isFavorite(_ entry: Entry) -> Bool {
        library.favorites.contains(entry.id)
    }

    private func systemLabel(for entry: Entry) -> String {
        switch entry.kind {
        case .arcade: return "Arcade"
        case .software(let sys): return library.softwareListDisplayName(for: sys) ?? sys
        }
    }

    // MARK: - Paging

    /// Paging is keyboard-only — ←/→. There are no chevrons: the card
    /// is a look-at-this surface, and the gallery behind it is where
    /// browsing belongs.
    @discardableResult
    private func step(_ delta: Int) -> KeyPress.Result {
        guard let entryID,
              let current = entries.firstIndex(where: { $0.id == entryID })
        else { return .handled }
        let next = current + delta
        guard entries.indices.contains(next) else { return .handled }
        self.entryID = entries[next].id
        return .handled
    }
}

// MARK: - Liquid Glass

/// Liquid Glass where the OS has it (macOS 26 Tahoe and later), the
/// closest pre-Tahoe material treatment everywhere else. The package
/// still deploys to macOS 14, so every glass call site goes through one
/// of these.
private extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

}


/// A centered detail card over a dimmed backdrop, living inside the
/// gallery rather than in a sheet. Same modal treatment as Peel's
/// upgrade card: click the backdrop or press esc to dismiss, and no
/// close button — a macOS modal of this shape doesn't carry one.
struct EntryDetailOverlay: View {
    let system: SystemNode
    let entries: [Entry]
    @Binding var entryID: Entry.ID?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.35))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { entryID = nil }

            EntryDetailView(system: system, entries: entries, entryID: $entryID)
                .background(Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 30)
                .padding(32)
        }
        .onExitCommand { entryID = nil }
    }
}
