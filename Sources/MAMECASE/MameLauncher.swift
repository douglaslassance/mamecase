import Foundation

enum MameLauncher {
    /// Launches MAME with the given args, working directory set to ~/.mame so
    /// relative paths in mame.ini (rompath, hashpath, etc.) resolve correctly.
    static func launch(executable: String, args: [String], workingDirectory: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = workingDirectory
        try p.run()
    }

    /// Build the argument list for an entry, prefixing `-rompath` with the
    /// combined paths (Mamecase settings + mame.ini) so MAME sees every
    /// location regardless of how it was configured. An optional controller
    /// scheme (basename of a `.cfg` in `ctrlrpath`) is passed via `-ctrlr`;
    /// an optional shader is passed via `-glsl_shader_mame1` (slot 1, so it
    /// layers on top of whatever the user already has in mame.ini).
    ///
    /// `statePath` is MAME's base state dir from mame.ini. For software-list
    /// entries we override `-state_directory` to a per-game subdirectory
    /// (`<statePath>/<system>/<software>`) so each cart on a shared driver
    /// gets its own save slots. Arcade is left alone — MAME already keys
    /// arcade state files by driver, which equals the game.
    static func arguments(for entry: Entry,
                          romPaths: [URL],
                          statePath: URL? = nil,
                          controllerScheme: String? = nil,
                          shader: String? = nil) -> [String] {
        var args: [String] = []
        if !romPaths.isEmpty {
            args.append("-rompath")
            args.append(romPaths.map(\.path).joined(separator: ";"))
        }
        if let scheme = controllerScheme,
           !scheme.trimmingCharacters(in: .whitespaces).isEmpty {
            args.append("-ctrlr")
            args.append(scheme)
        }
        if let shader, !shader.trimmingCharacters(in: .whitespaces).isEmpty {
            args.append("-glsl_shader_mame1")
            args.append(shader)
        }
        switch entry.kind {
        case .arcade:
            args.append(entry.shortName)
        case .software(let system):
            if let statePath {
                let perGame = statePath
                    .appendingPathComponent(system, isDirectory: true)
                    .appendingPathComponent(entry.shortName, isDirectory: true)
                try? FileManager.default.createDirectory(at: perGame,
                                                         withIntermediateDirectories: true)
                args.append("-state_directory")
                args.append(perGame.path)
            }
            args.append(system)
            args.append(entry.shortName)
        }
        return args
    }
}
