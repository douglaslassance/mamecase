import Foundation

/// Parses MAME's history dat once per session and serves per-entry text
/// from an in-memory index. Both distributed formats are read — the
/// current `history.xml` and the legacy `history.dat` text file (see
/// `HistoryDatParser`).
///
/// Arcade machines and console/computer software both live in the same
/// file: machines under `<system name="…">`, software under
/// `<item list="<software list>" name="…">`. So a Famicom cart's history
/// comes from the same place a coin-op's does, keyed by its software
/// list rather than by driver.
///
/// XML layout:
/// ```
/// <history>
///   <entry>
///     <software><item list="nes" name="100mandk"/></software>   (or)
///     <systems><system name="88games"/></systems>
///     <text>…</text>
///   </entry>
///   …
/// </history>
/// ```
/// Multiple `<item>` / `<system>` siblings per entry share the same body —
/// each one becomes a separate key in the index pointing at the same text.
actor HistoryProvider {
    static let shared = HistoryProvider()

    /// Key is `"arcade/<short>"` or `"<list>/<short>"`.
    private var index: [String: String] = [:]
    private var loadTask: Task<Void, Never>?
    private var loadedFrom: URL?

    static func key(for entry: Entry) -> String {
        switch entry.kind {
        case .arcade: return "arcade/\(entry.shortName)"
        case .software(let sys): return "\(sys)/\(entry.shortName)"
        }
    }

    func text(for entry: Entry, historyPaths: [URL]) async -> String? {
        await ensureLoaded(historyPaths: historyPaths)
        return index[HistoryProvider.key(for: entry)]
    }

    private func ensureLoaded(historyPaths: [URL]) async {
        let target = HistoryProvider.firstHistoryFile(in: historyPaths)
        if loadedFrom == target { return }
        if let inFlight = loadTask {
            await inFlight.value
            if loadedFrom == target { return }
        }
        loadedFrom = target
        index.removeAll()
        guard let target else { return }
        let task = Task.detached(priority: .utility) {
            HistoryFile.parse(url: target)
        }
        loadTask = Task { [weak self] in
            let parsed = await task.value
            await self?.acceptParsed(parsed, from: target)
        }
        await loadTask?.value
    }

    private func acceptParsed(_ parsed: [String: String], from url: URL) {
        guard loadedFrom == url else { return }
        index = parsed
        loadTask = nil
    }

    private static func firstHistoryFile(in dirs: [URL]) -> URL? {
        let fm = FileManager.default
        for dir in dirs {
            for name in ["history.xml", "history.dat"] {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

// MARK: - Format detection

/// The dat ships in two shapes and both are still in the wild: the
/// current `history.xml`, and the classic `history.dat` text format that
/// predates it. Sniff the head of the file and pick a parser.
private enum HistoryFile {
    static func parse(url: URL) -> [String: String] {
        looksLikeXML(url) ? HistoryParser.parse(url: url) : HistoryDatParser.parse(url: url)
    }

    private static func looksLikeXML(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return false }
        guard let text = String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1) else { return false }
        return text.contains("<?xml") || text.contains("<history")
    }
}

// MARK: - XML parsing

private final class HistoryParser: NSObject, XMLParserDelegate {
    private var current: [String] = []
    private var currentText: String = ""
    private var pendingKeys: [String] = []
    private var output: [String: String] = [:]

    static func parse(url: URL) -> [String: String] {
        guard let parser = XMLParser(contentsOf: url) else { return [:] }
        let delegate = HistoryParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return delegate.output }
        return delegate.output
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        current.append(elementName)
        switch elementName {
        case "entry":
            pendingKeys.removeAll()
            currentText = ""
        case "item":
            if let list = attributeDict["list"], let name = attributeDict["name"] {
                pendingKeys.append("\(list)/\(name)")
            }
        case "system":
            if let name = attributeDict["name"] {
                pendingKeys.append("arcade/\(name)")
            }
        case "text":
            currentText = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current.last == "text" { currentText += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        defer { _ = current.popLast() }
        if elementName == "entry" {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                for key in pendingKeys { output[key] = trimmed }
            }
            pendingKeys.removeAll()
            currentText = ""
        }
    }
}

// MARK: - Legacy history.dat parsing

/// Parser for the pre-XML `history.dat`:
///
/// ```
/// $info=puckman,puckmanf,
/// $bio
/// Pac-Man (c) 1980 Namco.
/// …
/// $end
/// ```
///
/// The tag before `=` names the set the following block belongs to:
/// `info` for arcade machines, and the software-list name (`nes`,
/// `snes`, `megadriv`, …) for console and computer software — the same
/// split `history.xml` expresses as `<system>` vs `<item list="…">`. A
/// block can be preceded by several tag lines, in which case they all
/// share one body.
private enum HistoryDatParser {
    static func parse(url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return [:] }

        var output: [String: String] = [:]
        var pendingKeys: [String] = []
        var body: [Substring] = []
        var inBody = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if inBody {
                if line.hasPrefix("$end") {
                    let joined = body.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty {
                        for key in pendingKeys { output[key] = joined }
                    }
                    pendingKeys.removeAll()
                    body.removeAll()
                    inBody = false
                } else {
                    body.append(line)
                }
                continue
            }
            if line.hasPrefix("$bio") {
                inBody = true
                body.removeAll()
                continue
            }
            // Anything else outside a block is a comment or blank except
            // the `$<tag>=<names>` lines naming the sets that follow.
            guard line.hasPrefix("$"), let equals = line.firstIndex(of: "=") else { continue }
            let tag = line[line.index(after: line.startIndex)..<equals]
            let list = (tag == "info") ? "arcade" : String(tag)
            for name in line[line.index(after: equals)...].split(separator: ",") {
                let short = name.trimmingCharacters(in: .whitespaces)
                if !short.isEmpty { pendingKeys.append("\(list)/\(short)") }
            }
        }
        return output
    }
}
