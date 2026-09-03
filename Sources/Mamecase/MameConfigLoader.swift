import Foundation

enum MameConfigError: Error, LocalizedError {
    case executableNotFound
    case iniNotReadable(URL)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: return "Could not find `mame` on PATH."
        case .iniNotReadable(let url): return "Could not read \(url.path)."
        }
    }
}

enum MameConfigLoader {
    static func load(settings: SettingsSnapshot) throws -> MameConfig {
        let ini = settings.resolvedMameIni
        let mameHome = settings.resolvedMameHome

        // MAME splits options across two files: mame.ini for core
        // emulator settings, ui.ini for the UI plugin's settings
        // (flyers_directory, covers_directory, categorypath, ui_path,
        // and an enriched historypath). We parse both and merge —
        // ui.ini wins when keys overlap because that's the file the
        // user actually edits through MAME's UI.
        var values = (try? parseIni(at: ini)) ?? [:]
        let uiIni = mameHome.appendingPathComponent("ui.ini")
        if let uiValues = try? parseIni(at: uiIni) {
            for (k, v) in uiValues { values[k] = v }
        }

        // ROM paths come straight from mame.ini's `rompath` line — Mamecase
        // doesn't merge in any side-channel list any more.
        let romPaths = dedupePreservingOrder(
            resolvePaths(values["rompath"] ?? "roms", base: mameHome)
        )

        let hashPaths = resolvePaths(values["hashpath"] ?? "hash", base: mameHome)
        let swPaths = resolvePaths(values["swpath"] ?? "software", base: mameHome)
        let snapDir = values["snapshot_directory"] ?? "snap"
        let snapPaths = resolvePaths(snapDir, base: mameHome)
        let ctrlrPaths = resolvePaths(values["ctrlrpath"] ?? "ctrlr", base: mameHome)
        let flyerPaths = resolvePaths(values["flyers_directory"] ?? "flyers", base: mameHome)
        let shaderPaths = resolvePaths(values["glsl_shader_path"] ?? "glsl", base: mameHome)
        let historyPaths = resolvePaths(values["historypath"] ?? "history", base: mameHome)
        // `state_directory` is single-valued in mame.ini (not a path
        // list); first segment wins if the user did separate by `;`.
        let statePath = resolvePaths(values["state_directory"] ?? "sta", base: mameHome).first
            ?? mameHome.appendingPathComponent("sta", isDirectory: true)
        // MAME's UI plugin reads/writes favorites.ini here. Default is
        // `ui` (relative to mameHome), confirmed against the MAME source
        // (OPTION_UI_PATH in moptions.h).
        let uiPaths = resolvePaths(values["ui_path"] ?? "ui", base: mameHome)
        // Mamecase convention: no MAME standard for "covers"; use a single
        // directory under mameHome unless we surface a setting later.
        let coverPaths = [mameHome.appendingPathComponent("covers", isDirectory: true)]

        // Everything else MAME's UI knows how to show — marquees,
        // cabinets, titles, control panels. Each kind names its own
        // ui.ini key and MAME's default for it, so this loop covers any
        // kind added to `MediaKind` later without touching the loader.
        var mediaPaths: [MediaKind: [URL]] = [:]
        for kind in MediaKind.allCases {
            guard let option = kind.directoryOption else { continue }
            mediaPaths[kind] = resolvePaths(values[option.key] ?? option.fallback, base: mameHome)
        }

        let executable = try locateMame(configured: settings.effectiveMameExecutablePath)

        return MameConfig(
            homePath: mameHome,
            romPaths: romPaths,
            hashPaths: hashPaths,
            snapPaths: snapPaths,
            swPaths: swPaths,
            ctrlrPaths: ctrlrPaths,
            flyerPaths: flyerPaths,
            coverPaths: coverPaths,
            mediaPaths: mediaPaths,
            shaderPaths: shaderPaths,
            historyPaths: historyPaths,
            statePath: statePath,
            uiPaths: uiPaths,
            executable: executable
        )
    }

    // MARK: - ini parsing

    private static func parseIni(at url: URL) throws -> [String: String] {
        let data = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]
        for rawLine in data.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            // MAME ini lines: "key   value" (whitespace-separated, value may contain spaces)
            guard let firstSpace = line.firstIndex(where: { $0.isWhitespace }) else {
                out[line] = ""
                continue
            }
            let key = String(line[..<firstSpace])
            let value = String(line[firstSpace...]).trimmingCharacters(in: .whitespaces)
            out[key] = stripQuotes(value)
        }
        return out
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2, s.first == "\"", s.last == "\"" else { return s }
        return String(s.dropFirst().dropLast())
    }

    // MARK: - Path resolution

    private static func resolvePaths(_ raw: String, base: URL) -> [URL] {
        raw.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { expand($0, base: base) }
    }

    private static func expand(_ path: String, base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else {
            url = base.appendingPathComponent(expanded)
        }
        // Resolve symlinks at the source so downstream callers see a
        // real directory. Without this, `FileManager.contentsOfDirectory(at:)`
        // rejects symlinked rompaths with ENOTDIR even though the
        // string-based variant follows them — see Foundation quirk
        // documented at the resolution site below.
        return url.resolvingSymlinksInPath()
    }

    private static func dedupePreservingOrder(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for u in urls {
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted {
                out.append(u)
            }
        }
        return out
    }

    // MARK: - Locate mame executable

    /// Resolve the executable. If the configured value is an absolute path, use it.
    /// Otherwise treat it as a name to look up on PATH (default: `mame`), then
    /// fall back to common Homebrew locations.
    private static func locateMame(configured: String) throws -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        let value = trimmed.isEmpty ? AppSettingsDefaults.mameExecutablePath : trimmed

        // Absolute or tilde path: use as-is if executable.
        if value.hasPrefix("/") || value.hasPrefix("~") {
            let expanded = (value as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
            throw MameConfigError.executableNotFound
        }

        // Bare name: look up via `which`.
        if let p = run("/usr/bin/which", [value])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !p.isEmpty {
            return p
        }
        for candidate in ["/opt/homebrew/bin/\(value)", "/usr/local/bin/\(value)"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw MameConfigError.executableNotFound
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
