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
