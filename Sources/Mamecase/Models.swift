import Foundation
import SwiftUI

enum EntryKind: Hashable, Sendable {
    case arcade
    case software(system: String)
}

struct Entry: Identifiable, Hashable, Sendable {
    let kind: EntryKind
    let shortName: String
    let displayName: String
    let year: String?
    let publisher: String?
    /// Disk-name strings from MAME's `<disk name="…">` elements (one per
    /// disc for the entry). For disc-based systems MAME accepts files
    /// named after the disk-name directly under `<rompath>/<system>/`,
    /// so we use these as alternate filenames during presence detection
    /// and ROM lookup. Empty for arcade and cartridge-only entries.
    var diskNames: [String] = []
    var owned: Bool = false

    /// Built once at construction rather than recomputed on access. The
    /// gallery reads `id` for every entry on every re-render (ForEach
    /// identity plus the selection and favourites lookups), so a
    /// computed property here meant tens of thousands of string
    /// allocations per frame while the window was being resized.
    let id: String

    init(kind: EntryKind,
         shortName: String,
         displayName: String,
         year: String?,
         publisher: String?,
         diskNames: [String] = [],
         owned: Bool = false) {
        self.kind = kind
        self.shortName = shortName
        self.displayName = displayName
        self.year = year
        self.publisher = publisher
        self.diskNames = diskNames
        self.owned = owned
        switch kind {
        case .arcade: self.id = "arcade/\(shortName)"
        case .software(let sys): self.id = "\(sys)/\(shortName)"
        }
    }
}

/// Aspect-ratio overrides for snap art by software-list name. Anything
/// not listed falls back to 4:3, which covers most arcade cabinets and
/// console TV outputs.
enum SnapAspectRatio {
    static func ratio(for entry: Entry) -> CGFloat {
        switch entry.kind {
        case .arcade: return 4.0/3.0
        case .software(let list):
            switch list {
            case "gameboy", "gbcolor", "supergb", "supergb2":
                return 10.0/9.0
            case "gba":
                return 3.0/2.0
            case "ngp", "ngpc":
                return 20.0/19.0
            case "lynx":
                return 1.6
            case "vectrex":
                return 3.0/4.0
            default:
                return 4.0/3.0
            }
        }
    }
}

/// Aspect-ratio overrides for flyer / box art by software-list name.
/// Boxes vary by system; we pick the Japanese release shape where
/// regions disagree (US/EU boxes get cropped to fit). 3:4 portrait is
/// the generic fallback.
enum FlyerAspectRatio {
    static func ratio(for entry: Entry) -> CGFloat {
        switch entry.kind {
        case .arcade:
            // Arcade flyers are advertising paper — usually portrait
            // about 3:4.
            return 3.0/4.0
        case .software(let list):
            switch list {
            case "nes", "famicom":
                return 5.0/7.0       // tall vertical Famicom box
            case "snes", "sfx":
                return 5.0/7.0
            case "megadriv", "genesis":
                return 5.0/7.0       // tall Mega Drive case
            case "mastersys", "smsj":
                return 5.0/7.0
            case "n64":
                return 4.0/5.0
            case "saturn":
                return 5.0/6.0       // CD jewel-case
            case "dreamcast":
                return 5.0/6.0
            case "psx", "ps1":
                return 5.0/6.0
            case "ps2":
                return 5.0/7.0
            case "pcecd", "pce", "pcecdrom", "tg16":
                return 5.0/6.0
            case "gameboy", "gbcolor":
                return 5.0/6.0       // boxed Game Boy / Game Boy Color
            case "gba":
                return 5.0/6.0
            case "ngp", "ngpc":
                return 5.0/6.0
            case "vectrex":
                return 4.0/5.0
            default:
                return 3.0/4.0
            }
        }
    }
}

struct SystemNode: Identifiable, Hashable {
    let id: String
    let displayName: String
    let count: Int
    let kind: Kind

    enum Kind: Hashable {
        case arcade
        case software(listName: String)
        /// Pseudo-system that pools entries from every real system —
        /// used by the Library sidebar ("All", "Recent") and playlists.
        case cross(scope: CrossScope)

        var isCrossSystem: Bool {
            if case .cross = self { return true }
            return false
        }

        /// SF Symbol used in the sidebar. Outline variants (no `.fill`)
        /// to match the lighter weight Apple uses for iTunes / Music
        /// sidebars. Arcade gets the same `memorychip` glyph as every
        /// other system — singling it out with a controller felt
        /// inconsistent.
        var sidebarIcon: String {
            switch self {
            case .arcade, .software: return "memorychip"
            case .cross(let scope):
                switch scope {
                case .all: return "rectangle.stack"
                case .recent: return "clock"
                case .playlist: return "play.square"
                }
            }
        }
    }

    enum CrossScope: Hashable {
        case all
        case recent
        case playlist(id: String)
    }
}

/// User-curated playlist of game entries. Persisted as JSON; populated
/// in Phase 5.
struct Playlist: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var entryIDs: [String]
}

/// Region buckets the user can filter the gallery by. `all` shows
/// everything; the others match the corresponding region tokens in
/// `DisplayName.format(...).flags`.
/// How the gallery arranges tiles.
enum LayoutMode: String, CaseIterable, Identifiable {
    case horizontalMasonry
    case verticalMasonry

    var id: String { rawValue }

    /// Custom SF-symbol-shaped asset shipped in our xcassets bundle so we
    /// match the look used by Peel.
    var moduleSymbol: String {
        switch self {
        case .verticalMasonry: return "square.masonry.vertical.2x2"
        case .horizontalMasonry: return "square.masonry.horizontal.2x2"
        }
    }

    var label: String {
        switch self {
        case .verticalMasonry: return "Vertical Masonry"
        case .horizontalMasonry: return "Horizontal Masonry"
        }
    }
}

enum RegionFilter: String, CaseIterable, Identifiable {
    case all
    case japan
    case usa
    case europe

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .all: return "🌍"
        case .japan: return "🇯🇵"
        case .usa: return "🇺🇸"
        case .europe: return "🇪🇺"
        }
    }

    var label: String {
        switch self {
        case .all: return "All Regions"
        case .japan: return "Japan"
        case .usa: return "USA"
        case .europe: return "Europe"
        }
    }

    /// Does this entry's display name pass the filter? Goes through the
    /// memoized formatter because the gallery re-runs this over the whole
    /// catalogue every time it rebuilds its entry list.
    @MainActor
    func matches(_ displayName: String) -> Bool {
        guard self != .all else { return true }
        let flags = FormattedDisplayName.format(displayName).flags
        return flags.contains(emoji)
    }
}

/// The gallery's filter state, bundled so `Library` can use it as a
/// memo-cache key instead of re-filtering the catalogue on every
/// `body` evaluation.
struct EntryFilter: Hashable {
    var hideMissing: Bool = false
    var favoritesOnly: Bool = false
    var failingOnly: Bool = false
    var region: RegionFilter = .all
    var search: String = ""
}

/// A kind of media we display in the gallery for an entry.
///
/// Naming note: MAME's `artwork/` directory refers specifically to bezels
/// and overlays drawn around the running game — distinct from the things
/// frontends show in a grid. We use **media** as the umbrella term for
/// snap / cover / flyer / marquee / title / etc.
///
/// `flyers` is an abstraction over MAME's "flyer" assets — for arcade
/// entries it resolves to the machine's flyer (mame.ini's
/// `flyers_directory`); for software-list entries it resolves to per-game
/// box art under a Mamecase-managed covers directory (defaults to
/// `~/.mame/covers/<list>/<short>.png`). Named `flyers` to mirror
/// mame.ini's terminology rather than coining a Mamecase-specific term.
enum MediaKind: String, CaseIterable, Identifiable {
    case flyers
    case snap
    case marquee
    case cabinet
    case title
    case cpanel

    /// Kinds the gallery grid offers as a browsing mode. The rest are
    /// supporting shots — worth a look on the detail card, but MAME's
    /// packs for them are usually partial, so browsing a whole library
    /// by them would be mostly placeholders.
    static let galleryCases: [MediaKind] = [.flyers, .snap]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flyers: return "Flyers"
        case .snap: return "Snap"
        case .marquee: return "Marquee"
        case .cabinet: return "Cabinet"
        case .title: return "Title"
        case .cpanel: return "Panel"
        }
    }

    var systemImage: String {
        switch self {
        case .flyers: return "rectangle.portrait.on.rectangle.portrait"
        case .snap: return "photo"
        case .marquee: return "sparkles"
        case .cabinet: return "arcade.stick.console"
        case .title: return "textformat"
        case .cpanel: return "arcade.stick"
        }
    }

    /// The `ui.ini` key holding this kind's directory, plus MAME's own
    /// default for it. `nil` for the two kinds `MameConfigLoader`
    /// resolves by hand: snap comes from mame.ini's `snapshot_directory`,
    /// and flyers falls back to the covers directory for software-list
    /// entries. Adding another kind is this entry plus a `label` and a
    /// `systemImage` — nothing else knows the list.
    var directoryOption: (key: String, fallback: String)? {
        switch self {
        case .flyers, .snap: return nil
        case .marquee: return ("marquees_directory", "marquees")
        case .cabinet: return ("cabinets_directory", "cabinets")
        case .title: return ("titles_directory", "titles")
        case .cpanel: return ("cpanels_directory", "cpanel")
        }
    }
}

/// Result of running `mame -verifyroms` / `-verifysoftware` against an entry.
enum RomStatus: String, Codable, Sendable {
    /// Every required file present and matches expected checksum.
    case good
    /// Playable, but some optional files are missing or have wrong CRCs.
    case bestAvailable
    /// Missing critical files or wrong checksums.
    case bad
    /// Romset is absent entirely from the rompath.
    case notFound
    /// Verification ran but the output couldn't be parsed (or the process
    /// failed for unrelated reasons).
    case error

    var label: String {
        switch self {
        case .good: return "Good"
        case .bestAvailable: return "Best Available"
        case .bad: return "Bad"
        case .notFound: return "Not Found"
        case .error: return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .bestAvailable: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .notFound: return "questionmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .good: return .green
        case .bestAvailable: return .yellow
        case .bad: return .red
        case .notFound: return .gray
        case .error: return .orange
        }
    }

    /// True when the verdict warrants the "failing verification" filter:
    /// outright bad, best-available (playable but flawed), or an audit
    /// that didn't parse cleanly. `.good` and `.notFound` are excluded —
    /// notFound is the "missing files" axis covered by its own toggle.
    var isFailing: Bool {
        switch self {
        case .bad, .bestAvailable, .error: return true
        case .good, .notFound: return false
        }
    }
}

struct MameConfig {
    /// ~/.mame
    let homePath: URL
    /// resolved absolute rompaths
    let romPaths: [URL]
    /// resolved hash dirs (where software list XMLs live)
    let hashPaths: [URL]
    /// resolved snap dirs
    let snapPaths: [URL]
    /// resolved software paths (mame's `swpath`)
    let swPaths: [URL]
    /// resolved controller-profile dirs (mame's `ctrlrpath`)
    let ctrlrPaths: [URL]
    /// resolved flyer dirs (mame's `flyers_directory`)
    let flyerPaths: [URL]
    /// resolved cover-art dirs (Mamecase convention; defaults to `<mameHome>/covers`)
    let coverPaths: [URL]
    /// resolved directories for the media kinds that come straight from
    /// a ui.ini directory option (marquees, cabinets, titles, control
    /// panels). Keyed by kind; a missing key means not configured.
    let mediaPaths: [MediaKind: [URL]]
    /// resolved shader directory (mame's `glsl_shader_path`, defaults to `glsl`)
    let shaderPaths: [URL]
    /// resolved history-dat directory (mame's `historypath`, defaults to `history`)
    let historyPaths: [URL]
    /// MAME's save-state base directory (`state_directory`, defaults to
    /// `sta`). MAME's own layout puts states under
    /// `<statePath>/<driver>/<slot>.sta`, which means every software-list
    /// game on a given driver shares its slots (every SNES cart writes
    /// into `sta/snes/`). Mamecase overrides `-state_directory` per
    /// launch to `<statePath>/<system>/<software>` so saves are
    /// per-software-list-entry instead.
    let statePath: URL
    /// resolved UI ini directories (mame's `ui_path`, defaults to `ui`).
    /// MAME reads/writes `favorites.ini` here, so Mamecase reads & rewrites
    /// the same file to round-trip favourites with MAME's own OSD.
    let uiPaths: [URL]
    /// path to mame executable
    let executable: String
}
