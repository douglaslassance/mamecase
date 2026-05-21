import Foundation

/// Read / write MAME's native `favorites.ini` (the file its UI plugin
/// uses for the "Add to favorites" feature). Format is 15 lines per
/// record after a `[ROOT_FOLDER]` header, mirroring MAME source at
/// `src/frontend/mame/ui/inifile.cpp`. By round-tripping through this
/// file, Mamecase favourites also appear in MAME's OSD and ride along
/// with any setup that's git-tracked under `~/.mame`.
enum FavoritesIni {
    /// MAME's per-entry record. Field names and order match its parser
    /// exactly — change either side and the other won't deserialise.
    fileprivate struct Record {
        var shortname: String
        var longname: String
        var parentname: String
        var year: String
        var publisher: String
        var supported: Int    // 0 = yes, 1 = partial, 2 = no
        var part: String
        var driver: String
        var listname: String  // software-list shortname; empty for arcade
        var interface: String
        var instance: String
        var startempty: Int   // 1 for an arcade machine launched bare
        var parentlongname: String
        var devicetype: String
        var available: Int    // 1 = ROM file present on disk
    }

    private static let fileName = "favorites.ini"

    /// MAME software-list names whose entries are CD-based — we use
    /// these to fill the `interface` / `instance` / `devicetype` fields.
    private static let discBasedLists: Set<String> = [
        "psx", "saturn", "dreamcast", "segacd", "pcecd", "tg16cd", "neogeo_cd",
    ]

    /// Software-list name → MAME driver name override. The default is
    /// "driver = listname", which works for most systems (snes, nes,
    /// gameboy, saturn, megadriv, …). PSX is the notable outlier: the
    /// `psx` list has no `psx` driver — we pick the parent JP driver
    /// since that's what MAME falls through to.
    private static let listToDriver: [String: String] = [
        "psx": "psj",
    ]

    // MARK: - Loading

    /// Return MAME favourites mapped to Mamecase `Entry.ID`s. Reads the
    /// first `favorites.ini` it finds along `uiPaths`. Missing file →
    /// empty set, no error.
    static func load(uiPaths: [URL]) -> Set<Entry.ID> {
        guard let url = existingFile(in: uiPaths),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var lines = text.split(omittingEmptySubsequences: false,
                               whereSeparator: { $0.isNewline })
            .map(String.init)
        // Skip the leading `[ROOT_FOLDER]` header (and any future
        // section markers).
        while let first = lines.first, first.hasPrefix("[") {
            lines.removeFirst()
        }
        var ids: Set<Entry.ID> = []
        var i = 0
        while i + 14 < lines.count {
            let shortname = lines[i]
            let listname = lines[i + 8]
            if shortname.isEmpty {
                i += 15
                continue
            }
            if listname.isEmpty {
                ids.insert("arcade/\(shortname)")
            } else {
                ids.insert("\(listname)/\(shortname)")
            }
            i += 15
        }
        return ids
    }

    // MARK: - Saving

    /// Rewrite `favorites.ini` to hold every entry in `ids`. The lookup
    /// table (`allEntries`) is needed because MAME stores per-record
    /// metadata (year, publisher, system info) beyond just the ID.
    /// Writes to the first path in `uiPaths`, creating it if needed.
    static func save(_ ids: Set<Entry.ID>, allEntries: [Entry], uiPaths: [URL]) {
        guard let writeDir = uiPaths.first else { return }
        let entryByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        var lines: [String] = ["[ROOT_FOLDER]"]
        for id in ids.sorted() {
            guard let entry = entryByID[id] else { continue }
            let record = makeRecord(for: entry)
            lines.append(contentsOf: serialize(record))
        }
        let body = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: writeDir,
                                                 withIntermediateDirectories: true)
        let dest = writeDir.appendingPathComponent(fileName)
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: dest)
        } else {
            try? body.write(to: dest, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private static func existingFile(in uiPaths: [URL]) -> URL? {
        let fm = FileManager.default
        for dir in uiPaths {
            let url = dir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func makeRecord(for entry: Entry) -> Record {
        switch entry.kind {
        case .arcade:
            return Record(
                shortname: entry.shortName,
                longname: entry.displayName,
                parentname: entry.shortName,
                year: entry.year ?? "",
                publisher: entry.publisher ?? "",
                supported: 0,
                part: "",
                driver: entry.shortName,
                listname: "",
                interface: "",
                instance: "",
                startempty: 1,
                parentlongname: "",
                devicetype: "",
                available: entry.owned ? 1 : 0
            )
        case .software(let list):
            let isDisc = discBasedLists.contains(list) || !entry.diskNames.isEmpty
            let mediaType = isDisc ? "cdrom" : "cart"
            return Record(
                shortname: entry.shortName,
                longname: entry.displayName,
                parentname: entry.shortName,
                year: entry.year ?? "",
                publisher: entry.publisher ?? "",
                supported: 0,
                part: mediaType,
                driver: listToDriver[list] ?? list,
                listname: list,
                interface: "\(list)_\(mediaType)",
                instance: mediaType,
                startempty: 0,
                parentlongname: "",
                devicetype: mediaType,
                available: entry.owned ? 1 : 0
            )
        }
    }

    private static func serialize(_ r: Record) -> [String] {
        [
            r.shortname,
            r.longname,
            r.parentname,
            r.year,
            r.publisher,
            String(r.supported),
            r.part,
            r.driver,
            r.listname,
            r.interface,
            r.instance,
            String(r.startempty),
            r.parentlongname,
            r.devicetype,
            String(r.available),
        ]
    }
}
