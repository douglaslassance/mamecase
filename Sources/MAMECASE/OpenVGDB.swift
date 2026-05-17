import Foundation

/// Looks up box-art URLs for software-list entries against the OpenVGDB
/// SQLite database (community-maintained mapping of game metadata).
///
/// The database is downloaded once on first use from the OpenVGDB release
/// (~6 MB zipped, ~50 MB extracted) into Application Support. Queries are
/// done by shelling out to `/usr/bin/sqlite3` to avoid a SQLite dependency.
///
/// Coverage caveats: OpenVGDB hasn't seen a new release since 2021 and the
/// hosted image URLs occasionally 404. Lookups here use the display-name
/// match (no system filter), so titles that exist on multiple systems
/// (e.g. "Super Mario Bros.") may pick a release from the wrong platform.
actor OpenVGDB {
    static let shared = OpenVGDB()

    private static let releaseURL = URL(string:
        "https://github.com/OpenVGDB/OpenVGDB/releases/download/v29.0/openvgdb.zip")!

    private var inFlightDownload: Task<Bool, Never>?
    private var downloadFailed: Bool = false

    private nonisolated var dbURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Mamecase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("openvgdb.sqlite")
    }

    /// True when the database file is on disk and ready to query.
    var isAvailable: Bool { FileManager.default.fileExists(atPath: dbURL.path) }

    /// Make sure the SQLite database exists locally. Downloads + extracts
    /// on first call. Subsequent calls are cheap.
    @discardableResult
    func ensureDatabase() async -> Bool {
        if isAvailable { return true }
        if downloadFailed { return false }
        if let existing = inFlightDownload { return await existing.value }
        let target = dbURL
        let task = Task.detached(priority: .utility) {
            await OpenVGDB.downloadDatabase(to: target)
        }
        inFlightDownload = task
        let ok = await task.value
        inFlightDownload = nil
        if !ok { downloadFailed = true }
        return ok
    }

    /// Look up a cover-art URL by exact case-insensitive title match.
    /// Returns nil if the DB isn't present or no row matches.
    func coverURL(forTitle title: String) async -> URL? {
        guard await ensureDatabase() else { return nil }
        let escaped = title.replacingOccurrences(of: "'", with: "''")
        let sql = """
        SELECT releaseCoverFront FROM RELEASES
        WHERE LOWER(releaseTitleName) = LOWER('\(escaped)')
          AND releaseCoverFront IS NOT NULL
        LIMIT 1;
        """
        guard let raw = await runQuery(sql),
              let url = URL(string: raw) else { return nil }
        return url
    }

    // MARK: - Download

    private static func downloadDatabase(to dest: URL) async -> Bool {
        let session = URLSession(configuration: .default)
        do {
            let (tmpURL, response) = try await session.download(from: OpenVGDB.releaseURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("Mamecase-vgdb-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-qq", "-o", tmpURL.path, "-d", staging.path]
            unzip.standardOutput = Pipe()
            unzip.standardError = Pipe()
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { return false }

            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            guard let sqlite = candidates.first(where: { $0.pathExtension.lowercased() == "sqlite" })
            else { return false }

            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: sqlite, to: dest)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Query

    private func runQuery(_ sql: String) async -> String? {
        let path = dbURL.path
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                p.arguments = [path, sql]
                let outPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = Pipe()
                do { try p.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                p.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let raw = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: raw.isEmpty ? nil : raw)
            }
        }
    }
}
