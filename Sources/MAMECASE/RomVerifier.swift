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
    static func verify(entry: Entry, executable: String, romPaths: [URL]) async -> RomStatus {
        let args = arguments(for: entry, romPaths: romPaths)
        let output = await runCapturing(executable: executable, args: args)
        return parse(output)
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

    // MARK: - Process

    private static func runCapturing(executable: String, args: [String]) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
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
