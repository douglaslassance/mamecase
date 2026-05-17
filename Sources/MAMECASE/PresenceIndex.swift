import Foundation

/// Scans `rompath` directories to determine which ROMs the user actually has.
///
/// MAME conventions:
///   * Arcade machines live at `<rompath>/<machine>.zip` (or `<machine>/`)
///   * Software list items live at `<rompath>/<system>/<software>.zip` (or `<software>/`)
struct PresenceIndex {
    /// Short names of arcade machines present on disk.
    let arcade: Set<String>
    /// system shortname → set of software shortnames present on disk.
    let softwareBySystem: [String: Set<String>]

    static let empty = PresenceIndex(arcade: [], softwareBySystem: [:])

    static func build(romPaths: [URL], knownSoftwareSystems: Set<String>) -> PresenceIndex {
        var arcade = Set<String>()
        var sw: [String: Set<String>] = [:]
        let fm = FileManager.default

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

                if isDir, knownSoftwareSystems.contains(item.lastPathComponent) {
                    // <rompath>/<system>/<software>(.zip|.7z|/)
                    let system = item.lastPathComponent
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
                            if childIsDir || childExt == "zip" || childExt == "7z" {
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
