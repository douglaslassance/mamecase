import Foundation
import SWCompression

enum ArchiveError: LocalizedError {
    case unsupported(String)
    case notFound(String)
    case readFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Unsupported archive type: .\(ext)"
        case .notFound(let name): return "Couldn't find \(name) inside the archive."
        case .readFailed(let url, let err): return "Failed to read \(url.lastPathComponent): \(err.localizedDescription)"
        }
    }
}

/// Pure-Swift archive reader for `.zip` and `.7z` files. Used to fish a
/// single media file out of a Progetto-SNAPS-style pack without extracting
/// the whole archive.
///
/// Loading the archive metadata loads the whole file into memory, which is
/// fine for the artwork packs we expect (~100s of MB at most). Decoded entry
/// bytes are kept only long enough to write them to the destination.
enum ArchiveExtractor {
    /// Try to extract the first entry whose path matches one of `candidates`
    /// (matched case-insensitively, with both `/` and `\` separators
    /// normalised). Writes to `destination` atomically. Returns the
    /// destination URL on success.
    static func extractFirst(matching candidates: [String],
                             from archive: URL,
                             to destination: URL) throws -> URL {
        let ext = archive.pathExtension.lowercased()
        let data: Data
        do {
            data = try Data(contentsOf: archive, options: .mappedIfSafe)
        } catch {
            throw ArchiveError.readFailed(archive, error)
        }

        let bytes: Data
        switch ext {
        case "zip":
            bytes = try extractFromZip(data: data, candidates: candidates)
        case "7z":
            bytes = try extractFrom7z(data: data, candidates: candidates)
        default:
            throw ArchiveError.unsupported(ext)
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .atomic)
        return destination
    }

    // MARK: - Containers

    private static func extractFromZip(data: Data, candidates: [String]) throws -> Data {
        let entries = try ZipContainer.open(container: data)
        for candidate in normalize(candidates) {
            for entry in entries {
                if normalize(entry.info.name) == candidate {
                    if let payload = entry.data { return payload }
                }
            }
        }
        throw ArchiveError.notFound(candidates.first ?? "")
    }

    private static func extractFrom7z(data: Data, candidates: [String]) throws -> Data {
        let entries = try SevenZipContainer.open(container: data)
        for candidate in normalize(candidates) {
            for entry in entries {
                if normalize(entry.info.name) == candidate {
                    if let payload = entry.data { return payload }
                }
            }
        }
        throw ArchiveError.notFound(candidates.first ?? "")
    }

    /// Extract every entry of `archive` to `cacheDir`. If every entry
    /// shares the same top-level directory (e.g. archive contains
    /// `snap/pacman.png`, `snap/streetfighter.png`, …), that prefix is
    /// stripped so the cache layout matches MAME's flat-directory model.
    static func extractAll(archive: URL, into cacheDir: URL) throws {
        let ext = archive.pathExtension.lowercased()
        let data: Data
        do {
            data = try Data(contentsOf: archive, options: .mappedIfSafe)
        } catch {
            throw ArchiveError.readFailed(archive, error)
        }

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let raw: [(name: String, payload: Data)]
        switch ext {
        case "zip":
            raw = try ZipContainer.open(container: data).compactMap { entry in
                guard let p = entry.data, !entry.info.name.isEmpty else { return nil }
                return (entry.info.name.replacingOccurrences(of: "\\", with: "/"), p)
            }
        case "7z":
            raw = try SevenZipContainer.open(container: data).compactMap { entry in
                guard let p = entry.data, !entry.info.name.isEmpty else { return nil }
                return (entry.info.name.replacingOccurrences(of: "\\", with: "/"), p)
            }
        default:
            throw ArchiveError.unsupported(ext)
        }

        for (name, payload) in stripCommonTopLevel(raw) {
            try writeEntry(name: name, payload: payload, into: cacheDir)
        }
    }

    /// If every entry path starts with the same `<X>/` prefix, return the
    /// list with that prefix removed. Otherwise return unchanged.
    private static func stripCommonTopLevel(_ entries: [(name: String, payload: Data)]) -> [(name: String, payload: Data)] {
        guard let first = entries.first?.name,
              let slash = first.firstIndex(of: "/") else { return entries }
        let prefix = String(first[..<slash]) + "/"
        let allShare = entries.allSatisfy { e in
            e.name.hasPrefix(prefix) || e.name == String(prefix.dropLast())
        }
        guard allShare else { return entries }
        return entries.compactMap { e in
            // Skip the prefix directory entry itself (if present).
            if e.name == String(prefix.dropLast()) { return nil }
            return (String(e.name.dropFirst(prefix.count)), e.payload)
        }
    }

    private static func writeEntry(name: String, payload: Data, into cacheDir: URL) throws {
        // Disallow paths that try to climb out of the cache directory.
        guard !name.contains("..") else { return }
        let dest = cacheDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try payload.write(to: dest, options: .atomic)
    }

    // MARK: - Path normalisation

    private static func normalize(_ list: [String]) -> [String] {
        list.map(normalize)
    }

    private static func normalize(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
            .lowercased()
    }
}
