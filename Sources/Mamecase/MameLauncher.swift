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

    /// Build the argument list for an entry. We rely on mame.ini for
    /// `rompath` / `hashpath` / etc. — `MameLauncher.launch` sets the
    /// process's working directory to mame's home so MAME reads the same
    /// ini Mamecase parsed. Only flags that we want to override or layer
    /// on top of the ini are emitted here:
    ///   - `-ctrlr <profile>` for a controller scheme (basename of a
    ///     `.cfg` in `ctrlrpath`).
    ///   - `-glsl_shader_mame1 <shader>` (slot 1) to layer over whatever
    ///     the user already has in mame.ini.
    ///   - `-state_directory <dir>` for software-list entries so each
    ///     cart gets its own save slots (MAME's default layout puts
    ///     every cart on a driver into the same slot directory).
    static func arguments(for entry: Entry,
                          statePath: URL? = nil,
                          controllerScheme: String? = nil,
                          shader: String? = nil) -> [String] {
        var args: [String] = []
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
