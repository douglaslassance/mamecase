import Foundation

/// Cover-art lookup for software-list entries against the
/// [libretro-thumbnails](https://github.com/libretro-thumbnails) per-system
/// repositories. Filenames in those repos follow the No-Intro convention,
/// which doesn't always match MAME's display strings, so we fetch the
/// directory listing once per system, cache it locally, and match
/// MAME→No-Intro names in-process.
///
/// Index disk cache: `~/Library/Caches/Mamecase/libretro-indexes/<repo>.json`.
/// Fetched from `https://api.github.com/repos/libretro-thumbnails/<repo>/git/trees/master?recursive=1`
/// — a single API call per system. Once the file exists on disk, no more
/// network traffic for matching.
actor LibretroThumbnails {
    static let shared = LibretroThumbnails()

    private var indexes: [String: [String]] = [:]
    private var inFlight: [String: Task<[String], Never>] = [:]
    private var failedRepos: Set<String> = []

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// Map from a MAME software-list short name to the libretro thumbnail
    /// repo name. Covers the systems Mamecase users are most likely to
    /// browse; unmapped lists return nil and skip the libretro path.
    private static let listToRepo: [String: String] = [
        "nes": "Nintendo_-_Nintendo_Entertainment_System",
        "famicom": "Nintendo_-_Nintendo_Entertainment_System",
        "fds": "Nintendo_-_Family_Computer_Disk_System",
        "snes": "Nintendo_-_Super_Nintendo_Entertainment_System",
        "sfx": "Nintendo_-_Super_Nintendo_Entertainment_System",
        "n64": "Nintendo_-_Nintendo_64",
        "gameboy": "Nintendo_-_Game_Boy",
        "gbcolor": "Nintendo_-_Game_Boy_Color",
        "gba": "Nintendo_-_Game_Boy_Advance",
        "vboy": "Nintendo_-_Virtual_Boy",
        "megadriv": "Sega_-_Mega_Drive_-_Genesis",
        "genesis": "Sega_-_Mega_Drive_-_Genesis",
        "32x": "Sega_-_32X",
        "segacd": "Sega_-_Mega-CD_-_Sega_CD",
        "mastersys": "Sega_-_Master_System_-_Mark_III",
        "smsj": "Sega_-_Master_System_-_Mark_III",
        "gamegear": "Sega_-_Game_Gear",
        "sg1000": "Sega_-_SG-1000",
        "saturn": "Sega_-_Saturn",
        "dreamcast": "Sega_-_Dreamcast",
        "psx": "Sony_-_PlayStation",
        "ps2": "Sony_-_PlayStation_2",
        "psp": "Sony_-_PlayStation_Portable",
        "ngp": "SNK_-_Neo_Geo_Pocket",
        "ngpc": "SNK_-_Neo_Geo_Pocket_Color",
        "neogeo": "SNK_-_Neo_Geo",
        "pce": "NEC_-_PC_Engine_-_TurboGrafx-16",
        "tg16": "NEC_-_PC_Engine_-_TurboGrafx-16",
        "pcecd": "NEC_-_PC_Engine_CD_-_TurboGrafx-CD",
        "tg16cd": "NEC_-_PC_Engine_CD_-_TurboGrafx-CD",
        "lynx": "Atari_-_Lynx",
        "a2600": "Atari_-_2600",
        "a5200": "Atari_-_5200",
        "a7800": "Atari_-_7800",
        "ajaguar": "Atari_-_Jaguar",
        "coleco": "Coleco_-_ColecoVision",
        "intv": "Mattel_-_Intellivision",
        "vectrex": "GCE_-_Vectrex",
        "wswan": "Bandai_-_WonderSwan",
        "wscolor": "Bandai_-_WonderSwan_Color",
    ]

    /// Resolve to a libretro `Named_Boxarts/<name>.png` URL for the entry,
    /// or nil when the system isn't mapped or no filename matches.
    func coverURL(for entry: Entry) async -> URL? {
        guard case .software(let list) = entry.kind,
              let repo = LibretroThumbnails.listToRepo[list] else { return nil }
        let names = await loadIndex(repo: repo)
        guard !names.isEmpty,
              let matched = matchName(displayName: entry.displayName, in: names)
        else { return nil }
        return LibretroThumbnails.boxartURL(repo: repo, filename: matched)
    }

    // MARK: - Index loading

    private func loadIndex(repo: String) async -> [String] {
        if let cached = indexes[repo] { return cached }
        if failedRepos.contains(repo) { return [] }
        if let inflight = inFlight[repo] { return await inflight.value }

        if let disk = LibretroThumbnails.readDiskIndex(repo: repo), !disk.isEmpty {
            indexes[repo] = disk
            return disk
        }

        let session = self.session
        let task = Task<[String], Never> {
            await LibretroThumbnails.fetchIndex(repo: repo, session: session)
        }
        inFlight[repo] = task
        let result = await task.value
        inFlight.removeValue(forKey: repo)
        if result.isEmpty {
            failedRepos.insert(repo)
        } else {
            indexes[repo] = result
            LibretroThumbnails.writeDiskIndex(repo: repo, names: result)
        }
        return result
    }

    private static func fetchIndex(repo: String, session: URLSession) async -> [String] {
        guard let url = URL(string:
            "https://api.github.com/repos/libretro-thumbnails/\(repo)/git/trees/master?recursive=1")
        else { return [] }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            struct Tree: Decodable {
                let tree: [Item]
                struct Item: Decodable {
                    let path: String
                    let type: String
                }
            }
            let decoded = try JSONDecoder().decode(Tree.self, from: data)
            return decoded.tree.compactMap { item -> String? in
                guard item.type == "blob",
                      item.path.hasPrefix("Named_Boxarts/"),
                      item.path.hasSuffix(".png") else { return nil }
                let filename = String(item.path.dropFirst("Named_Boxarts/".count))
                return String(filename.dropLast(".png".count))
            }
        } catch {
            return []
        }
    }

    // MARK: - Disk cache

    private static func indexFileURL(repo: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Mamecase/libretro-indexes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(repo).json")
    }

    private static func readDiskIndex(repo: String) -> [String]? {
        let url = indexFileURL(repo: repo)
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return names
    }

    private static func writeDiskIndex(repo: String, names: [String]) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: indexFileURL(repo: repo), options: .atomic)
    }

    private static func boxartURL(repo: String, filename: String) -> URL? {
        guard let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string:
            "https://raw.githubusercontent.com/libretro-thumbnails/\(repo)/master/Named_Boxarts/\(encoded).png")
    }

    // MARK: - Name matching

    /// Match strategy, applied in order until one returns:
    ///   1. Case-insensitive exact match on the full display name.
    ///   2. "Strict" normalize — drop bracketed tags + parens that look
    ///      like region/lang/revision metadata, fold parens that look
    ///      like subtitles back as inline words. Catches reordered
    ///      subtitles such as
    ///         "Tengai Makyou Zero Shounen Jump no Shou (Jpn)" ↔
    ///         "Tengai Makyou Zero (Japan) (Shounen Jump no Shou)"
    ///   3. "Loose" normalize — same as before this change: strip every
    ///      `(…)` / `[…]` group. Fallback for cases where one side has
    ///      subtitle parens the other side just doesn't (e.g. libretro
    ///      may add an extra clarifying paren we shouldn't require MAME
    ///      to have).
    private func matchName(displayName: String, in names: [String]) -> String? {
        let displayLower = displayName.lowercased()
        if let exact = names.first(where: { $0.lowercased() == displayLower }) {
            return exact
        }
        let strict = LibretroThumbnails.normalize(displayName, mode: .foldSubtitles)
        if !strict.isEmpty,
           let m = names.first(where: {
               LibretroThumbnails.normalize($0, mode: .foldSubtitles) == strict
           }) {
            return m
        }
        let loose = LibretroThumbnails.normalize(displayName, mode: .stripAll)
        guard !loose.isEmpty else { return nil }
        return names.first(where: {
            LibretroThumbnails.normalize($0, mode: .stripAll) == loose
        })
    }

    fileprivate enum NormalizeMode {
        /// Drop bracketed tags. Drop parens whose contents look like
        /// region/language/revision metadata. Fold remaining parens
        /// back into the main string as inline words.
        case foldSubtitles
        /// Drop every `(…)` and `[…]` group entirely. Behaviour we had
        /// before the rule-based matcher landed.
        case stripAll
    }

    /// Lowercase, normalise paren handling per `mode`, replace `&` / `_`
    /// with spaces (libretro uses `_` as a filename-safe stand-in for
    /// `&`), and apply the article ↔ trailing-comma convention so
    ///   "The Goonies II (Euro)"        ↔ "goonies ii"
    ///   "Goonies II, The (Europe)"     ↔ "goonies ii"
    /// hash to the same key.
    fileprivate static func normalize(_ s: String, mode: NormalizeMode) -> String {
        // Filename-safe substitution libretro uses for `&`. Replace
        // both with a space so MAME's "Rockman & Forte" and libretro's
        // "Rockman _ Forte" normalise the same way.
        let cleaned = s.replacingOccurrences(of: "&", with: " ")
                       .replacingOccurrences(of: "_", with: " ")
            // Strip diacritics so "Légende" ↔ "Legende" hash the same.
            .folding(options: .diacriticInsensitive, locale: .current)
        var n = parenStripped(cleaned, mode: mode).lowercased()
        // Fold + trim whitespace BEFORE article handling — paren
        // removal leaves trailing spaces that would defeat the
        // `", the"` suffix check otherwise.
        while n.contains("  ") {
            n = n.replacingOccurrences(of: "  ", with: " ")
        }
        n = n.trimmingCharacters(in: .whitespaces)
        // Apply article rules per " - " segment, then rejoin. Compound
        // titles split the article across the dash differently on each
        // side: MAME writes "The Legend of Zelda - A Link to the Past",
        // libretro writes "Legend of Zelda, The - A Link to the Past".
        // Per-segment stripping reconciles both to
        // "legend of zelda - link to the past".
        let segments = n.components(separatedBy: " - ").map(stripArticles)
        return segments.joined(separator: " - ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Drop a leading `the / a / an ` or trailing `, the / , a / , an`
    /// from a single title segment.
    private static func stripArticles(_ s: String) -> String {
        var n = s
        for article in ["the ", "a ", "an "] {
            if n.hasPrefix(article) {
                n = String(n.dropFirst(article.count))
                break
            }
        }
        for suffix in [", the", ", a", ", an"] {
            if n.hasSuffix(suffix) {
                n = String(n.dropLast(suffix.count))
                break
            }
        }
        return n
    }

    /// Apply the chosen `mode` to all `(…)` / `[…]` groups in `s`.
    /// Brackets are always dropped (No-Intro `[!]` / serials).
    private static func parenStripped(_ s: String, mode: NormalizeMode) -> String {
        var result = ""
        var parenDepth = 0
        var bracketDepth = 0
        var paren = ""
        for ch in s {
            if bracketDepth > 0 {
                if ch == "[" { bracketDepth += 1 }
                else if ch == "]" { bracketDepth -= 1 }
                continue
            }
            if parenDepth > 0 {
                if ch == "(" {
                    parenDepth += 1
                    paren.append(ch)
                } else if ch == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 {
                        // Decide what to do with the closed paren group.
                        switch mode {
                        case .foldSubtitles where !looksLikeRegionTag(paren):
                            result.append(" ")
                            result.append(paren)
                            result.append(" ")
                        default:
                            break // drop
                        }
                        paren = ""
                    } else {
                        paren.append(ch)
                    }
                } else {
                    paren.append(ch)
                }
                continue
            }
            switch ch {
            case "[": bracketDepth = 1
            case "(": parenDepth = 1
            default: result.append(ch)
            }
        }
        return result
    }

    /// Region / language / revision tags that we treat as metadata
    /// rather than subtitle text. Multi-token paren groups split on `,`
    /// — if every token passes this filter, the group is metadata.
    private static let regionTokens: Set<String> = [
        // Regions
        "usa", "europe", "japan", "world", "asia", "korea", "australia",
        "jpn", "jp", "us", "eu", "euro", "aus", "kor",
        "ntsc-u", "ntsc-j", "pal", "pal-e",
        // Languages
        "en", "fr", "de", "ja", "es", "it", "nl", "sv", "pt", "ko", "zh",
        "fi", "no", "da", "pl", "ru",
        // Build / market flags
        "proto", "prototype", "beta", "sample", "demo", "kiosk",
        "not for sale", "virtual console", "arcade",
        // Multi-disc tag without a number — the numbered version is
        // handled by the regex below.
        "alt",
    ]

    private static func looksLikeRegionTag(_ s: String) -> Bool {
        let parts = s.lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            if regionTokens.contains(part) { return true }
            // "Rev 1", "Rev A", "Rev. B"
            if part.range(of: #"^rev\.?\s*[0-9a-z.]+$"#,
                          options: .regularExpression) != nil { return true }
            // "v1", "v1.0", "v1.0.3"
            if part.range(of: #"^v\s*[0-9]+(\.[0-9]+)*$"#,
                          options: .regularExpression) != nil { return true }
            // "Disc 1", "Disc 1 of 3"
            if part.range(of: #"^disc\s+[0-9]+(\s+of\s+[0-9]+)?$"#,
                          options: .regularExpression) != nil { return true }
            // ISO-style dates "1996-05-14"
            if part.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
                          options: .regularExpression) != nil { return true }
            return false
        }
    }
}
