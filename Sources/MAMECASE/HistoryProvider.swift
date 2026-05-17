import Foundation

/// Parses MAME's `history.xml` once per session and serves per-entry text
/// from an in-memory index.
///
/// File layout:
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
            HistoryParser.parse(url: target)
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
