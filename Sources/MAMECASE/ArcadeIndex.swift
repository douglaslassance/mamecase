import Foundation

/// Indexes arcade machines by running `mame -listfull` and (optionally)
/// filtering to ROMs the user actually has on disk in `rompath`.
enum ArcadeIndex {
    /// Run `mame -listfull` and return every machine MAME knows about.
    /// Format per line (after header): `shortname    "Display Name"`.
    static func listAll(executable: String) async throws -> [Entry] {
        let output = try await runCapturing(executable: executable, args: ["-listfull"])
        var entries: [Entry] = []
        entries.reserveCapacity(50_000)

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Skip header line: "Name:             Description:"
            if trimmed.hasPrefix("Name:") { continue }

            guard let firstSpace = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
            let name = String(trimmed[..<firstSpace])
            var rest = String(trimmed[firstSpace...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") { rest.removeFirst() }
            if rest.hasSuffix("\"") { rest.removeLast() }

            entries.append(Entry(
                kind: .arcade,
                shortName: name,
                displayName: rest.isEmpty ? name : rest,
                year: nil,
                publisher: nil
            ))
        }
        return entries
    }

    /// Filters `entries` to those whose ROM is present somewhere in `romPaths`.
    /// Matches `<name>.zip` or a directory named `<name>`.
    static func filterByPresence(_ entries: [Entry], romPaths: [URL]) -> [Entry] {
        let names = Set(collectAvailableNames(in: romPaths))
        return entries.filter { names.contains($0.shortName) }
    }

    /// Returns the set of short names available across all rompaths
    /// (looking for both `<name>.zip` and directories named `<name>`).
    static func collectAvailableNames(in romPaths: [URL]) -> [String] {
        var result: [String] = []
        let fm = FileManager.default
        for dir in romPaths {
            guard let items = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                let name = item.deletingPathExtension().lastPathComponent
                let ext = item.pathExtension.lowercased()
                if ext == "zip" || ext == "7z" || (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    result.append(name)
                }
            }
        }
        return result
    }

    // MARK: - Process

    private static func runCapturing(executable: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                do {
                    try p.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
