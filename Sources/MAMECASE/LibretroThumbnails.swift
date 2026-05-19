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

    /// Match strategy, in order:
    ///   1. Case-insensitive exact match on the full display name.
    ///   2. Match after stripping `(…)` / `[…]` tags and normalising the
    ///      "The X" ↔ "X, The" article convention (libretro / No-Intro
    ///      files articles trailing, MAME's hash XMLs put them leading).
    ///   3. Otherwise nil.
    private func matchName(displayName: String, in names: [String]) -> String? {
        let displayLower = displayName.lowercased()
        if let exact = names.first(where: { $0.lowercased() == displayLower }) {
            return exact
        }
        let target = LibretroThumbnails.normalize(displayName)
        guard !target.isEmpty else { return nil }
        return names.first(where: { LibretroThumbnails.normalize($0) == target })
    }

    /// Strip `(…)` / `[…]` tag groups, lowercase, fold whitespace, and
    /// normalise the leading/trailing article so e.g.
    ///   "The Goonies II (Euro)"        ↔ "goonies ii"
    ///   "Goonies II, The (Europe)"     ↔ "goonies ii"
    /// fall onto the same key.
    private static func normalize(_ s: String) -> String {
        let stripped = stripTags(s).lowercased()
        var n = stripped
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
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func stripTags(_ s: String) -> String {
        var result = ""
        var depth = 0
        for ch in s {
            if ch == "(" || ch == "[" {
                depth += 1
            } else if ch == ")" || ch == "]" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                result.append(ch)
            }
        }
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
