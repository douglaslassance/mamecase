import Foundation

struct SoftwareList {
    let name: String          // e.g. "megadriv"
    let description: String   // e.g. "Sega MegaDrive/Genesis cartridges"
    let entries: [Entry]
}

final class SoftwareListParser: NSObject, XMLParserDelegate {
    private var listName: String = ""
    private var listDescription: String = ""

    private var currentSoftwareName: String?
    private var currentDescription: String?
    private var currentYear: String?
    private var currentPublisher: String?
    private var currentText: String = ""
    private var currentElement: String = ""

    private var entries: [Entry] = []

    /// Parse a single softwarelist XML file.
    static func parse(url: URL) -> SoftwareList? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let delegate = SoftwareListParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return SoftwareList(
            name: delegate.listName.isEmpty
                ? url.deletingPathExtension().lastPathComponent
                : delegate.listName,
            description: delegate.listDescription,
            entries: delegate.entries
        )
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        switch elementName {
        case "softwarelist":
            listName = attributeDict["name"] ?? ""
            listDescription = attributeDict["description"] ?? ""
        case "software":
            currentSoftwareName = attributeDict["name"]
            currentDescription = nil
            currentYear = nil
            currentPublisher = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "description":
            if currentDescription == nil { currentDescription = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "year":
            if currentYear == nil { currentYear = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "publisher":
            if currentPublisher == nil { currentPublisher = currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "software":
            if let name = currentSoftwareName {
                entries.append(Entry(
                    kind: .software(system: listName),
                    shortName: name,
                    displayName: currentDescription ?? name,
                    year: currentYear,
                    publisher: currentPublisher
                ))
            }
            currentSoftwareName = nil
        default: break
        }
        currentText = ""
    }
}
