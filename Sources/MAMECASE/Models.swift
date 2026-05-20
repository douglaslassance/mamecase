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
    var owned: Bool = false

    var id: String {
        switch kind {
        case .arcade: return "arcade/\(shortName)"
        case .software(let sys): return "\(sys)/\(shortName)"
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

/// Aspect-ratio overrides for cover/box art by software-list name. Boxes
/// vary by system; we pick the Japanese release shape where regions
/// disagree (US/EU boxes get cropped to fit). 3:4 portrait is the
/// generic fallback.
enum CoverArtAspectRatio {
    static func ratio(for entry: Entry) -> CGFloat {
        switch entry.kind {
        case .arcade:
            // Arcade "cover art" maps to flyers — usually portrait paper
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

    /// Does this entry's display name pass the filter?
    func matches(_ displayName: String) -> Bool {
        guard self != .all else { return true }
        let flags = DisplayName.format(displayName).flags
        return flags.contains(emoji)
    }
}

/// A kind of media we display in the gallery for an entry.
///
/// Naming note: MAME's `artwork/` directory refers specifically to bezels
/// and overlays drawn around the running game — distinct from the things
/// frontends show in a grid. We use **media** as the umbrella term for
/// snap / cover / flyer / marquee / title / etc.
///
/// `coverArt` is an abstraction: for arcade entries it resolves to the
/// machine's flyer (from `flyers_directory` in mame.ini); for software-list
/// entries it resolves to per-game cover art under a MAMECASE-managed
/// covers directory (defaults to `~/.mame/covers/<list>/<short>.png`).
enum MediaKind: String, CaseIterable, Identifiable {
    case coverArt
    case snap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coverArt: return "Cover Art"
        case .snap: return "Snap"
        }
    }

    var systemImage: String {
        switch self {
        case .coverArt: return "rectangle.portrait.on.rectangle.portrait"
        case .snap: return "photo"
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
    /// resolved cover-art dirs (MAMECASE convention; defaults to `<mameHome>/covers`)
    let coverPaths: [URL]
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
    /// path to mame executable
    let executable: String
}
