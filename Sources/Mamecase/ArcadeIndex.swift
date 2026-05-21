import Foundation

/// Indexes arcade machines by running `mame -listxml` and parsing the
/// resulting XML stream. We use `-listxml` rather than `-listfull` so we
/// get year + manufacturer per machine in addition to the description.
enum ArcadeIndex {
    static func listAll(executable: String) async throws -> [Entry] {
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("mame-listxml-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: dump) }
        try await captureToFile(executable: executable,
                                args: ["-listxml"],
                                destination: dump)
        return ListXMLParser.parse(url: dump)
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

    // MARK: - Process plumbing

    /// Run `executable args…` and pipe stdout into `destination`. Used for
    /// `-listxml` which produces hundreds of MB of output we don't want to
    /// hold in memory.
    private static func captureToFile(executable: String,
                                      args: [String],
                                      destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let handle: FileHandle
                do {
                    handle = try FileHandle(forWritingTo: destination)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                p.standardOutput = handle
                p.standardError = Pipe()
                do { try p.run() } catch {
                    try? handle.close()
                    continuation.resume(throwing: error)
                    return
                }
                p.waitUntilExit()
                try? handle.close()
                continuation.resume()
            }
        }
    }
}

// MARK: - SAX parser

private final class ListXMLParser: NSObject, XMLParserDelegate {
    private var entries: [Entry] = []
    private var currentText: String = ""

    private var currentName: String?
    private var currentIsDevice: Bool = false
    private var currentRunnable: Bool = true
    private var currentDescription: String?
    private var currentYear: String?
    private var currentManufacturer: String?

    static func parse(url: URL) -> [Entry] {
        guard let parser = XMLParser(contentsOf: url) else { return [] }
        let delegate = ListXMLParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        if elementName == "machine" {
            currentName = attributeDict["name"]
            currentIsDevice = attributeDict["isdevice"] == "yes"
            currentRunnable = attributeDict["runnable"] != "no"
            currentDescription = nil
            currentYear = nil
            currentManufacturer = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "description":
            if currentDescription == nil { currentDescription = text }
        case "year":
            if currentYear == nil { currentYear = text }
        case "manufacturer":
            if currentManufacturer == nil { currentManufacturer = text }
        case "machine":
            if let name = currentName, !currentIsDevice, currentRunnable {
                entries.append(Entry(
                    kind: .arcade,
                    shortName: name,
                    displayName: currentDescription ?? name,
                    year: currentYear,
                    publisher: currentManufacturer
                ))
            }
            currentName = nil
        default: break
        }
        currentText = ""
    }
}
