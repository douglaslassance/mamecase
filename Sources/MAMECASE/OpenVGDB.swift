import Foundation
import SQLite3

/// Looks up box-art URLs for software-list entries against the OpenVGDB
/// SQLite database (community-maintained mapping of game metadata).
///
/// The database is downloaded once on first use from the OpenVGDB release
/// (~6 MB zipped, ~50 MB extracted) into Application Support. Queries go
/// through the in-process `SQLite3` C API — no process spawn per lookup.
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
    /// Memoized title → URL? results so we don't re-query for repeat tiles.
    private var titleCache: [String: URL?] = [:]
    /// Opaque sqlite3 handle, lazily opened, kept alive for the process.
    private var db: OpaquePointer?

    private nonisolated var dbURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Mamecase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("openvgdb.sqlite")
    }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: dbURL.path) }

    deinit {
        if let db { sqlite3_close(db) }
    }

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
        if let cached = titleCache[title] { return cached }
        guard await ensureDatabase() else {
            titleCache[title] = nil
            return nil
        }
        let result = query(title: title)
        titleCache[title] = result
        return result
    }

    // MARK: - SQLite query

    private func query(title: String) -> URL? {
        if db == nil { openDatabase() }
        guard let db else { return nil }
        let sql = """
        SELECT releaseCoverFront FROM RELEASES
        WHERE LOWER(releaseTitleName) = LOWER(?1)
          AND releaseCoverFront IS NOT NULL
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1)!,
                                      to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, title, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        return URL(string: String(cString: cstr))
    }

    private func openDatabase() {
        var handle: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = handle
        } else {
            if let handle { sqlite3_close(handle) }
        }
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
}
