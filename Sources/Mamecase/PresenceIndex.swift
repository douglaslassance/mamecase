import Foundation

/// Scans `rompath` directories to determine which ROMs the user actually has.
///
/// MAME conventions:
///   * Arcade machines live at `<rompath>/<machine>.zip` (or `<machine>/`).
///   * Software list items live at `<rompath>/<system>/<software>.{zip,7z,chd}`
///     or `<rompath>/<system>/<software>/`. CD-based systems (PSX, Saturn,
///     Dreamcast, …) commonly ship files named after the `<disk name="…">`
///     declared in the MAME hash XML (e.g. `crash bandicoot (usa).chd`) rather
///     than after the software shortname (`crash.chd`). We accept both:
///     filenames matching either a software shortname OR a disk name in
///     that system's hash XML are tagged as owned for the canonical entry.
struct PresenceIndex {
    /// Short names of arcade machines present on disk.
    var arcade: Set<String>
    /// system shortname → set of software shortnames present on disk.
    var softwareBySystem: [String: Set<String>]

    static let empty = PresenceIndex(arcade: [], softwareBySystem: [:])

    /// Build a presence index from disk. `softwareLists` is required so
    /// the index can resolve disk-name filenames (`sat-0834-…`) back to
    /// the canonical software shortname (`guardheru`).
    static func build(romPaths: [URL], softwareLists: [SoftwareList]) -> PresenceIndex {
        var arcade = Set<String>()
        var sw: [String: Set<String>] = [:]
        let fm = FileManager.default

        // diskName → shortname lookup, per system. Built once up front.
        var diskNameMap: [String: [String: String]] = [:]
        let knownSystems = Set(softwareLists.map(\.name))
        for list in softwareLists {
            var map: [String: String] = [:]
            for entry in list.entries {
                for disk in entry.diskNames {
                    // First mapping wins; later duplicates (across clones)
                    // resolve to whichever entry was parsed first.
                    if map[disk] == nil {
                        map[disk] = entry.shortName
                    }
                }
            }
            if !map.isEmpty {
                diskNameMap[list.name] = map
            }
        }

        for rom in romPaths {
            guard let items = try? fm.contentsOfDirectory(
                at: rom,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items {
                let name = item.deletingPathExtension().lastPathComponent
                let ext = item.pathExtension.lowercased()
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDir, knownSystems.contains(item.lastPathComponent) {
                    // <rompath>/<system>/<software>(.zip|.7z|.chd|/) or
                    // <rompath>/<system>/<disk-name>.chd
                    let system = item.lastPathComponent
                    let perSystemDiskMap = diskNameMap[system] ?? [:]
                    var owned = sw[system] ?? Set<String>()
                    if let children = try? fm.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for child in children {
                            let childName = child.deletingPathExtension().lastPathComponent
                            let childExt = child.pathExtension.lowercased()
                            let childIsDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                            guard childIsDir || ["zip", "7z", "chd"].contains(childExt) else { continue }
                            // Resolve a disk-name match back to its
                            // canonical software shortname; otherwise
                            // record the filename as-is and let
                            // ownership tagging match by shortname.
                            if let canonical = perSystemDiskMap[childName] {
                                owned.insert(canonical)
                            } else {
                                owned.insert(childName)
                            }
                        }
                    }
                    sw[system] = owned
                } else if isDir || ext == "zip" || ext == "7z" {
                    arcade.insert(name)
                }
            }
        }
        return PresenceIndex(arcade: arcade, softwareBySystem: sw)
    }
}
