import Foundation

/// Runs MAME's audit (`-verifyroms` / `-verifysoftware`) for a single entry
/// and parses the one-line status report from stdout/stderr.
///
/// MAME prints lines like:
///   `romset pacman is good`
///   `romset xxx is bad`
///   `romset xxx is best available`
///   `romset xxx not found`
enum RomVerifier {
    /// Result of one MAME audit pass: a parsed status plus a short
    /// human-readable explanation drawn from the audit output, suitable
    /// for tooltips. Nil when there's nothing useful to add (e.g. status
    /// is good, or MAME ran but printed only its banner).
    struct Result {
        let status: RomStatus
        let details: String?
    }

    static func verify(entry: Entry, executable: String, romPaths: [URL]) async -> Result {
        let args = arguments(for: entry, romPaths: romPaths)
        let output = await runCapturing(executable: executable, args: args)
        let status = parse(output)
        return Result(status: status, details: extractDetails(output, status: status))
    }

    // MARK: - Arguments

    private static func arguments(for entry: Entry, romPaths: [URL]) -> [String] {
        var args: [String] = []
        if !romPaths.isEmpty {
            args.append("-rompath")
            args.append(romPaths.map(\.path).joined(separator: ";"))
        }
        switch entry.kind {
        case .arcade:
            args.append(contentsOf: ["-verifyroms", entry.shortName])
        case .software(let system):
            args.append(contentsOf: ["-verifysoftware", "\(system):\(entry.shortName)"])
        }
        return args
    }

    // MARK: - Parsing

    /// MAME emits a single status line; we look at the whole output to be
    /// resilient against headers/warnings prepended by some builds.
    private static func parse(_ output: String) -> RomStatus {
        let lower = output.lowercased()
        if lower.contains("is good") { return .good }
        if lower.contains("is best available") { return .bestAvailable }
        if lower.contains("not found") { return .notFound }
        if lower.contains("is bad") || lower.contains("is incorrect") { return .bad }
        return .error
    }

    /// Pulls the audit's "what went wrong" lines out of MAME's output:
    /// per-ROM CRC mismatches, missing files, parent-set warnings. Drops
    /// the leading banner / `Using…` / `Total time` chatter that's noise
    /// for a tooltip. Caps to 3 lines and ~240 chars so the tooltip
    /// stays readable.
    private static func extractDetails(_ output: String, status: RomStatus) -> String? {
        guard status != .good, status != .notFound else { return nil }
        let interesting: [String] = output
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let l = line.lowercased()
                guard !l.isEmpty else { return false }
                if l.hasPrefix("mame ") || l.hasPrefix("using ") { return false }
                if l.hasPrefix("romset ") && (l.contains(" is ") || l.contains(" not found")) {
                    // Drop the "romset X is bad" summary — its info is
                    // already conveyed by the status enum/badge.
                    return false
                }
                return l.contains("rom ") || l.contains("crc") || l.contains("missing")
                    || l.contains("not found") || l.contains("bad") || l.contains("warn")
            }
        guard !interesting.isEmpty else { return nil }
        let joined = interesting.prefix(3).joined(separator: "\n")
        if joined.count > 240 {
            return String(joined.prefix(240)) + "…"
        }
        return joined
    }

    // MARK: - Process

    private static func runCapturing(executable: String, args: [String]) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            // `.utility` so a background `verifyAll()` pass doesn't
            // contend with UI work. The user can still launch / scroll
            // / search while the audit walks the library.
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                do { try p.run() } catch {
                    continuation.resume(returning: "")
                    return
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: out + "\n" + err)
            }
        }
    }
}
