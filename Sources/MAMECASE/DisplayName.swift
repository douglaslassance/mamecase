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
        "world": "🌐",
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
            if ch == "(" {
                // Scan to the matching close paren (no nesting in practice).
                let groupStart = raw.index(after: idx)
                if let groupEnd = raw[groupStart...].firstIndex(of: ")") {
                    let inner = String(raw[groupStart..<groupEnd])
                    let (regions, leftover) = splitRegions(inner)
                    for region in regions where !seenFlags.contains(region) {
                        seenFlags.insert(region)
                        collectedFlags.append(region)
                    }
                    if let leftover {
                        // Some tokens weren't regions → keep them.
                        cleaned += "(\(leftover))"
                    } else if cleaned.hasSuffix(" ") {
                        // Strip the trailing space left behind by the
                        // removed group so we don't end up with "Name  text".
                        cleaned.removeLast()
                    }
                    idx = raw.index(after: groupEnd)
                    continue
                }
            }
            cleaned.append(ch)
            idx = raw.index(after: idx)
        }

        // Collapse whitespace introduced by stripping groups.
        let collapsed = cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return Formatted(name: collapsed, flags: collectedFlags.joined())
    }

    /// Split a parenthetical's inner text on `,` and partition tokens into
    /// (matched region flags, non-region leftovers as a re-joined string).
    private static func splitRegions(_ inner: String) -> (flags: [String], leftover: String?) {
        let tokens = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var flags: [String] = []
        var leftovers: [String] = []
        for token in tokens where !token.isEmpty {
            if let flag = regionFlags[token.lowercased()] {
                flags.append(flag)
            } else {
                leftovers.append(token)
            }
        }
        let leftoverString = leftovers.isEmpty ? nil : leftovers.joined(separator: ", ")
        return (flags, leftoverString)
    }
}
