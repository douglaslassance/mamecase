import Foundation

/// Parses ROM display names (as they appear in MAME hash XMLs and similar
/// dumps) and strips region tags out of the parenthetical groups, returning
/// the cleaned name plus a flag-emoji string.
///
/// Examples:
///   "Sonic the Hedgehog (Euro, USA)"          → "Sonic the Hedgehog", "🇪🇺🇺🇸"
///   "Streets of Rage (Euro, USA, Rev. A)"     → "Streets of Rage (Rev. A)", "🇪🇺🇺🇸"
///   "QuackShot … (World, Alt PCB)"            → "QuackShot … (Alt PCB)", "🌐"
///   "Mario Bros."                             → "Mario Bros.", ""
enum DisplayName {
    /// Map of lower-cased region tokens to a flag emoji.
    private static let regionFlags: [String: String] = [
        "euro": "🇪🇺", "europe": "🇪🇺", "pal": "🇪🇺",
        "usa": "🇺🇸", "us": "🇺🇸", "ntsc": "🇺🇸",
        "japan": "🇯🇵", "jpn": "🇯🇵", "jp": "🇯🇵",
        "world": "🌍",
        "uk": "🇬🇧", "england": "🇬🇧",
        "france": "🇫🇷", "fra": "🇫🇷", "fre": "🇫🇷",
        "germany": "🇩🇪", "ger": "🇩🇪", "deu": "🇩🇪",
        "spain": "🇪🇸", "spa": "🇪🇸",
        "italy": "🇮🇹", "ita": "🇮🇹",
        "brazil": "🇧🇷", "bra": "🇧🇷",
        "china": "🇨🇳", "chi": "🇨🇳", "chn": "🇨🇳",
        "korea": "🇰🇷", "kor": "🇰🇷",
        "asia": "🌏",
        "australia": "🇦🇺", "aus": "🇦🇺",
        "russia": "🇷🇺", "rus": "🇷🇺",
        "taiwan": "🇹🇼", "twn": "🇹🇼",
        "hong kong": "🇭🇰",
    ]

    struct Formatted {
        let name: String
        let flags: String
    }

    static func format(_ raw: String) -> Formatted {
        var cleaned = ""
        var collectedFlags: [String] = []
        var seenFlags = Set<String>()

        var idx = raw.startIndex
        while idx < raw.endIndex {
            let ch = raw[idx]
            if ch == "(" || ch == "[" {
                let closer: Character = (ch == "(") ? ")" : "]"
                let groupStart = raw.index(after: idx)
                if let groupEnd = raw[groupStart...].firstIndex(of: closer) {
                    let inner = String(raw[groupStart..<groupEnd])
                    for region in regionsIn(inner) where !seenFlags.contains(region) {
                        seenFlags.insert(region)
                        collectedFlags.append(region)
                    }
                    if cleaned.hasSuffix(" ") {
                        cleaned.removeLast()
                    }
                    idx = raw.index(after: groupEnd)
                    continue
                }
            }
            cleaned.append(ch)
            idx = raw.index(after: idx)
        }

        let collapsed = cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return Formatted(name: collapsed, flags: collectedFlags.joined())
    }

    /// Comma-split a tag's inner text and return any tokens that match the
    /// region map.
    private static func regionsIn(_ inner: String) -> [String] {
        inner.split(separator: ",")
            .compactMap { regionFlags[$0.trimmingCharacters(in: .whitespaces).lowercased()] }
    }
}
