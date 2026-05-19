import Foundation

/// Helpers for offering `brew install mame` when the user doesn't have MAME
/// on PATH but does have Homebrew.
enum BrewInstaller {
    /// Returns the absolute path of `brew` if it exists on the standard
    /// Homebrew prefixes (`/opt/homebrew` on Apple Silicon, `/usr/local`
    /// on Intel). Nil otherwise.
    static func brewExecutable() -> String? {
        let fm = FileManager.default
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs `brew install mame` and waits for it to finish. Returns the
    /// process exit status (0 on success). Output is discarded — the user
    /// sees the result reflected in the library reload.
    static func installMame() async -> Int32 {
        await install(package: "mame")
    }

    /// Run `brew upgrade mame`. Same shape as `installMame`.
    static func upgradeMame() async -> Int32 {
        await upgrade(package: "mame")
    }

    /// Run `<executable> -help` and return the first line, which is
    /// where MAME prints its banner (e.g. `MAME v0.260 (mame0260)`).
    /// Returns nil if the process fails or prints nothing useful.
    static func mameVersion(executable: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = ["-help"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let first = text
                    .split(whereSeparator: { $0.isNewline })
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
                continuation.resume(returning: (first?.isEmpty == false) ? first : nil)
            }
        }
    }

    /// True if MAME is currently installed via Homebrew (the executable
    /// lives under a Homebrew prefix).
    static func isMameBrewManaged() -> Bool {
        let candidates = ["/opt/homebrew/bin/mame", "/usr/local/bin/mame"]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True if `brew outdated --quiet mame` says an update is available.
    /// Falls back to false on any failure.
    static func isMameOutdated() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                guard let brew = brewExecutable() else {
                    continuation.resume(returning: false)
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = ["outdated", "--quiet", "mame"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.contains("mame"))
            }
        }
    }

    private static func upgrade(package: String) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let brew = brewExecutable() else {
                    continuation.resume(returning: -1)
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = ["upgrade", package]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                do {
                    try p.run()
                } catch {
                    continuation.resume(returning: -1)
                    return
                }
                p.waitUntilExit()
                continuation.resume(returning: p.terminationStatus)
            }
        }
    }

    /// Generic `brew install <pkg>` wrapper used by feature detection
    /// (e.g. offering to install `sevenzip` when a `.7z` archive needs
    /// extracting but `7zz` isn't present).
    static func install(package: String) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let brew = brewExecutable() else {
                    continuation.resume(returning: -1)
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = ["install", package]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                do {
                    try p.run()
                } catch {
                    continuation.resume(returning: -1)
                    return
                }
                p.waitUntilExit()
                continuation.resume(returning: p.terminationStatus)
            }
        }
    }
}
