import Foundation
import SwiftUI

enum EntryKind: Hashable {
    case arcade
    case software(system: String)
}

struct Entry: Identifiable, Hashable {
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

struct SystemNode: Identifiable, Hashable {
    let id: String
    let displayName: String
    let count: Int
    let kind: Kind

    enum Kind: Hashable {
        case arcade
        case software(listName: String)
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
enum RomStatus: String, Codable {
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
    /// path to mame executable
    let executable: String
}
