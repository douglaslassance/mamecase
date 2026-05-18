import Foundation

enum RomDownloadError: LocalizedError {
    case notFound(String)
    case http(Int, String)
    case writeFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): return "Archive doesn't have \(name).zip."
        case .http(let code, let name): return "Archive returned HTTP \(code) for \(name).zip."
        case .writeFailed(let url, let err): return "Couldn't write \(url.lastPathComponent): \(err.localizedDescription)"
        }
    }
}

/// Downloads arcade ROMs from the Internet Archive's `mame-merged` item.
///
/// URL pattern: `https://archive.org/download/mame-merged/<short>.zip`.
/// Same source as the user's standalone `download_latest_roms.py` but called
/// directly via URLSession — no Python dependency.
actor RomDownloader {
    static let shared = RomDownloader()

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 1800 // 30 min for the largest sets
        self.session = URLSession(configuration: cfg)
    }

    /// Downloads the named ROM to `destination`. `baseURL` is the user-
    /// configurable prefix (default `https://archive.org/download/mame-merged/`);
    /// we append `<shortname>.zip`. Writes atomically; on failure the
    /// destination is untouched.
    func download(shortName: String, baseURL: String, to destination: URL) async throws -> URL {
        guard let encoded = shortName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { throw RomDownloadError.notFound(shortName) }
        let trimmedBase = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        guard let url = URL(string: "\(trimmedBase)\(encoded).zip")
        else { throw RomDownloadError.notFound(shortName) }

        let (tmpURL, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let http = response as? HTTPURLResponse else {
            throw RomDownloadError.http(0, shortName)
        }
        if http.statusCode == 404 {
            throw RomDownloadError.notFound(shortName)
        }
        if http.statusCode != 200 {
            throw RomDownloadError.http(http.statusCode, shortName)
        }

        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tmpURL, to: destination)
        } catch {
            throw RomDownloadError.writeFailed(destination, error)
        }
        return destination
    }
}
