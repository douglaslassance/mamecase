import Foundation

enum ArchiveError: LocalizedError {
    case unsupported(String)
    case noExtractor(String)
    case extractFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Unsupported archive type: .\(ext)"
        case .noExtractor(let tool): return "Couldn't find `\(tool)` on disk."
        case .extractFailed(let code, let stderr):
            return "Extraction failed (exit \(code)): \(stderr.isEmpty ? "no output" : stderr)"
        }
    }
}

/// Extracts ROM/media archives using system CLI tools.
///
/// - `.zip` → `/usr/bin/unzip` (shipped with macOS).
/// - `.7z`  → `7zz` (or legacy `7z`) discovered under the standard Homebrew
///   prefixes. If absent, extraction throws `ArchiveError.noExtractor` and
///   callers should treat the archive as if it weren't there.
///
/// The archive is extracted into a temp staging directory; if it contains
/// a single top-level wrapper directory (e.g. `snap/`), that wrapper is
/// peeled off before the contents are moved into the destination. This
/// keeps the cache layout flat regardless of how the archive was packed.
enum ArchiveExtractor {
    static func extractAll(archive: URL, into cacheDir: URL) throws {
        let ext = archive.pathExtension.lowercased()
        let staging = try makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }

        switch ext {
        case "zip":
            try runUnzip(archive: archive, into: staging)
        case "7z":
            try runSevenZip(archive: archive, into: staging)
        default:
            throw ArchiveError.unsupported(ext)
        }

        let source = effectiveContentRoot(at: staging)
        try moveContents(from: source, to: cacheDir)
    }

    // MARK: - Extractor invocations

    private static func runUnzip(archive: URL, into outDir: URL) throws {
        let unzip = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzip) else {
            throw ArchiveError.noExtractor("unzip")
        }
        try run(tool: unzip, args: ["-qq", "-o", archive.path, "-d", outDir.path])
    }

    private static func runSevenZip(archive: URL, into outDir: URL) throws {
        let candidates = [
            "/opt/homebrew/bin/7zz",
            "/usr/local/bin/7zz",
            "/opt/homebrew/bin/7z",
            "/usr/local/bin/7z",
        ]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ArchiveError.noExtractor("7zz")
        }
        try run(tool: tool, args: ["x", "-aoa", "-bd", "-y", "-o\(outDir.path)", archive.path])
    }

    private static func run(tool: String, args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe()
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw ArchiveError.extractFailed(p.terminationStatus, err)
        }
    }

    // MARK: - Staging + prefix stripping

    private static func makeStagingDir() throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mamecase-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// If `staging` contains exactly one visible directory and nothing else,
    /// return that directory. Otherwise return `staging` unchanged.
    private static func effectiveContentRoot(at staging: URL) -> URL {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: staging,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else {
            return staging
        }
        guard items.count == 1 else { return staging }
        let item = items[0]
        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDir ? item : staging
    }

    /// Move every visible top-level entry from `source` into `dest`. If a
    /// destination entry already exists it's removed first (so this acts
    /// like an idempotent re-extract).
    private static func moveContents(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: source,
                                               includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])
        for item in items {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: item, to: target)
        }
    }
}
