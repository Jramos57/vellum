import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// High-level app-facing API for opening, editing, and saving EPUB publications.
///
/// Use this service when integrating `vellum` into an app data layer.
public struct EPUBPublicationService: Sendable {
    /// Creates a publication service.
    public init() {}

    /// Opens an EPUB from disk and resolves app-facing publication data.
    ///
    /// The package is extracted once to a temporary directory owned by the returned
    /// ``PublicationResources``. The directory is removed automatically when that
    /// object is released, or earlier via ``PublicationResources/removeExtractedContent()``.
    ///
    /// - Parameter url: Location of the EPUB archive.
    /// - Returns: An ``OpenedPublication`` with models and extracted resources.
    /// - Throws: ``VellumError`` when parsing or I/O fails.
    public func open(url: URL) throws -> OpenedPublication {
        try openSync(url: url)
    }

    private func openSync(url: URL) throws -> OpenedPublication {
        try ZipTool.validateMimetypeConstraints(archiveURL: url)

        let extractionRoot = try makeExtractionDirectory()
        do {
            try ZipTool.extractArchive(url, to: extractionRoot)
            let book = try EPUBParser().parseExtractedEPUB(at: extractionRoot)
            let resources = try makePublicationResources(root: extractionRoot, book: book)
            return OpenedPublication(
                publication: PublicationResolver.resolve(book),
                resources: resources
            )
        } catch {
            try? FileManager.default.removeItem(at: extractionRoot)
            throw error
        }
    }

    /// Opens an EPUB from disk and resolves app-facing publication data.
    ///
    /// - Parameter url: Location of the EPUB archive.
    /// - Returns: An ``OpenedPublication`` with models and extracted resources.
    /// - Throws: ``VellumError`` when parsing or I/O fails.
    public func open(url: URL) async throws -> OpenedPublication {
        try openSync(url: url)
    }

    /// Opens an EPUB from in-memory archive data.
    ///
    /// - Parameter data: Raw EPUB bytes.
    /// - Returns: An ``OpenedPublication`` with models and extracted resources.
    /// - Throws: ``VellumError`` when parsing or I/O fails.
    public func open(data: Data) throws -> OpenedPublication {
        try openDataSync(data)
    }

    private func openDataSync(_ data: Data) throws -> OpenedPublication {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-open-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try data.write(to: tempURL)
            return try openSync(url: tempURL)
        } catch let error as VellumError {
            throw error
        } catch {
            throw VellumError.ioFailure("Unable to open EPUB data: \(error.localizedDescription)")
        }
    }

    /// Opens an EPUB from in-memory archive data.
    ///
    /// - Parameter data: Raw EPUB bytes.
    /// - Returns: An ``OpenedPublication`` with models and extracted resources.
    /// - Throws: ``VellumError`` when parsing or I/O fails.
    public func open(data: Data) async throws -> OpenedPublication {
        try openDataSync(data)
    }

    /// Opens an EPUB from disk as an editable model.
    ///
    /// Unknown OPF metadata entries are preserved for best-effort round-trip during save.
    ///
    /// - Parameters:
    ///   - url: Location of the EPUB archive.
    ///   - includeLegacyNCX: Include NCX output on save.
    /// - Returns: An ``EditablePublication``.
    /// - Throws: ``VellumError`` when parsing or I/O fails.
    public func openEditable(url: URL, includeLegacyNCX: Bool = true) throws -> EditablePublication {
        try ZipTool.validateMimetypeConstraints(archiveURL: url)

        let extractionRoot = try makeExtractionDirectory()
        defer { try? FileManager.default.removeItem(at: extractionRoot) }

        try ZipTool.extractArchive(url, to: extractionRoot)
        let book = try EPUBParser().parseExtractedEPUB(at: extractionRoot)
        let preserved = try loadPreservedMetadataEntries(root: extractionRoot)
        let resources = try makePublicationResources(root: extractionRoot, book: book)
        let publication = PublicationResolver.resolve(book) { href in
            try? resources.data(forHref: href)
        }
        return EPUBPublicationEditor().makeEditable(
            from: publication,
            includeLegacyNCX: includeLegacyNCX,
            preservedMetadataEntries: preserved
        )
    }

    /// Opens an EPUB from in-memory data as an editable model.
    ///
    /// Unknown OPF metadata entries are preserved for best-effort round-trip during save.
    ///
    /// - Parameters:
    ///   - data: Raw EPUB bytes.
    ///   - includeLegacyNCX: Include NCX output on save.
    /// - Returns: An ``EditablePublication``.
    /// - Throws: ``VellumError`` when parsing or I/O fails.
    public func openEditable(data: Data, includeLegacyNCX: Bool = true) throws -> EditablePublication {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-open-editable-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try data.write(to: tempURL)
            return try openEditable(url: tempURL, includeLegacyNCX: includeLegacyNCX)
        } catch let error as VellumError {
            throw error
        } catch {
            throw VellumError.ioFailure("Unable to open editable EPUB data: \(error.localizedDescription)")
        }
    }

    /// Saves an editable publication to disk as an EPUB 3 archive.
    ///
    /// The editable model is validated before writing.
    ///
    /// - Parameters:
    ///   - editable: The editable publication to save.
    ///   - outputURL: Destination archive URL.
    /// - Throws: ``VellumError`` when validation or writing fails.
    public func save(_ editable: EditablePublication, to outputURL: URL) throws {
        let validated = try EPUBPublicationEditor().apply(.setNavigationOverride(editable.navigationOverride), to: editable)
        try EditablePublicationWriter.write(validated, outputURL: outputURL)
    }

    /// Saves an editable publication and returns EPUB archive bytes.
    ///
    /// - Parameter editable: The editable publication to save.
    /// - Returns: The EPUB archive as `Data`.
    /// - Throws: ``VellumError`` when validation or writing fails.
    public func save(_ editable: EditablePublication) throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-save-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try save(editable, to: outputURL)
        return try Data(contentsOf: outputURL)
    }

    private func makeExtractionDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-resources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePublicationResources(root: URL, book: EPUBBook) throws -> PublicationResources {
        let containerURL = root.appendingPathComponent(Internal.containerPath)
        guard let opfPath = try ContainerRootfileFinder.findOPFPath(at: containerURL) else {
            throw VellumError.ioFailure("Unable to resolve OPF path from container.xml.")
        }
        let opfBase = root.appendingPathComponent(opfPath).deletingLastPathComponent()
        return PublicationResources(
            rootURL: root,
            opfBaseURL: opfBase,
            hrefs: book.manifest.map(\.href),
            managedRootURL: root
        )
    }

    private func loadPreservedMetadataEntries(root: URL) throws -> [String] {
        let containerURL = root.appendingPathComponent(Internal.containerPath)
        guard let opfPath = try ContainerRootfileFinder.findOPFPath(at: containerURL) else {
            throw VellumError.ioFailure("Unable to resolve OPF path from container.xml.")
        }
        let opfURL = root.appendingPathComponent(opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        return OPFMetadataPreserver.extractUnknownMetadataEntries(fromOPF: opf)
    }
}

enum PublicationResolver {
    static func resolve(_ book: EPUBBook, resourceDataProvider: ((String) -> Data?)? = nil) -> Publication {
        let resources = book.manifest.map { item in
            ResourceItem(
                id: item.id,
                href: item.href,
                mediaType: item.mediaType,
                properties: item.properties,
                data: resourceDataProvider?(normalizeHref(item.href))
            )
        }
        let manifestIndex = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        let hrefIndex = Dictionary(uniqueKeysWithValues: resources.map { (normalizeHref($0.href), $0) })

        let readingOrder: [ReadingOrderItem] = book.spine.compactMap { spineItem in
            guard
                let chapter = book.chapters.first(where: { $0.id == spineItem.idref }),
                let resource = manifestIndex[spineItem.idref]
            else {
                return nil
            }
            return ReadingOrderItem(
                id: chapter.id,
                href: chapter.href,
                title: chapter.title,
                xhtml: chapter.xhtml,
                plainText: chapter.plainText,
                mediaType: resource.mediaType
            )
        }

        let toc = book.toc.map { NavigationItem(label: $0.label, href: $0.href) }
        let landmarks: [NavigationItem] = readingOrder.first.map {
            [NavigationItem(label: "Start", href: $0.href)]
        } ?? []
        let pageList = readingOrder.enumerated().map { index, item in
            NavigationItem(label: "Page \(index + 1)", href: item.href)
        }

        return Publication(
            metadata: book.metadata,
            readingOrder: readingOrder,
            navigation: NavigationTree(toc: toc, landmarks: landmarks, pageList: pageList),
            resources: resources,
            manifestIndex: manifestIndex,
            hrefIndex: hrefIndex,
            coverResource: resolveCoverResource(
                book: book,
                manifestIndex: manifestIndex,
                hrefIndex: hrefIndex
            )
        )
    }

    static func resolveCoverResource(
        book: EPUBBook,
        manifestIndex: [String: ResourceItem],
        hrefIndex: [String: ResourceItem]
    ) -> ResourceItem? {
        if let coverItem = book.manifest.first(where: { $0.properties.contains("cover-image") }),
           let resource = manifestIndex[coverItem.id] {
            return resource
        }

        if let coverItemID = book.coverItemID, let resource = manifestIndex[coverItemID] {
            return resource
        }

        if let coverGuideHref = book.coverGuideHref,
           let resource = hrefIndex[normalizeHref(coverGuideHref)] {
            return resource
        }

        return nil
    }

    static func normalizeHref(_ href: String) -> String {
        String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(href))
    }
}

private enum ContainerRootfileFinder {
    private final class Delegate: NSObject, XMLParserDelegate {
        var rootfilePath: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String : String] = [:]
        ) {
            if elementName == "rootfile" {
                rootfilePath = attributeDict["full-path"]
            }
        }
    }

    static func findOPFPath(at containerURL: URL) throws -> String? {
        let data = try Data(contentsOf: containerURL)
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.rootfilePath
    }
}

private enum EditablePublicationWriter {
    static func write(_ editable: EditablePublication, outputURL: URL) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let oebps = temp.appendingPathComponent(Internal.oebps)
        let metaInf = temp.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)

        try Data("application/epub+zip".utf8).write(to: temp.appendingPathComponent("mimetype"))
        try Data(containerXML.utf8).write(to: metaInf.appendingPathComponent("container.xml"))

        for chapter in editable.chapters {
            let url = oebps.appendingPathComponent(chapter.href)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(chapter.xhtml.utf8).write(to: url)
        }
        for asset in editable.assets {
            let url = oebps.appendingPathComponent(asset.href)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try asset.data.write(to: url)
        }

        let nav = buildNav(editable: editable)
        try Data(nav.utf8).write(to: oebps.appendingPathComponent("nav.xhtml"))
        if editable.includeLegacyNCX {
            let ncx = buildNCX(editable: editable)
            try Data(ncx.utf8).write(to: oebps.appendingPathComponent("toc.ncx"))
        }

        let metadata = EPUBMetadata(
            identifier: editable.metadata.identifier,
            title: editable.metadata.title,
            creator: editable.metadata.creator,
            language: editable.metadata.language,
            modified: Date(),
            publisher: editable.metadata.publisher,
            description: editable.metadata.description,
            rights: editable.metadata.rights
        )
        let opf = buildOPF(editable: editable, metadata: metadata)
        try Data(opf.utf8).write(to: oebps.appendingPathComponent("content.opf"))

        try ZipTool.makeArchive(from: temp, output: outputURL)
        try ZipTool.validateMimetypeConstraints(archiveURL: outputURL)
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static func buildOPF(editable: EditablePublication, metadata: EPUBMetadata) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var manifestItems: [String] = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
        ]
        if editable.includeLegacyNCX {
            manifestItems.append(#"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#)
        }
        for chapter in editable.chapters {
            manifestItems.append(#"<item id="\#(chapter.id.xmlEscaped())" href="\#(chapter.href.xmlEscaped())" media-type="application/xhtml+xml"/>"#)
        }
        for asset in editable.assets {
            let properties = asset.properties.joined(separator: " ")
            if properties.isEmpty {
                manifestItems.append(#"<item id="\#(asset.id.xmlEscaped())" href="\#(asset.href.xmlEscaped())" media-type="\#(asset.mediaType.xmlEscaped())"/>"#)
            } else {
                manifestItems.append(#"<item id="\#(asset.id.xmlEscaped())" href="\#(asset.href.xmlEscaped())" media-type="\#(asset.mediaType.xmlEscaped())" properties="\#(properties.xmlEscaped())"/>"#)
            }
        }

        let spineItems = editable.chapters.map { #"<itemref idref="\#($0.id.xmlEscaped())"/>"# }.joined(separator: "\n    ")
        let tocAttr = editable.includeLegacyNCX ? #" toc="ncx""# : ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(metadata.identifier.xmlEscaped())</dc:identifier>
            <dc:title>\(metadata.title.xmlEscaped())</dc:title>
            <dc:creator>\(metadata.creator.xmlEscaped())</dc:creator>
            <dc:language>\(metadata.language.xmlEscaped())</dc:language>
            <meta property="dcterms:modified">\(formatter.string(from: metadata.modified))</meta>
            \(metadata.publisher.map { "<dc:publisher>\($0.xmlEscaped())</dc:publisher>" } ?? "")
            \(metadata.description.map { "<dc:description>\($0.xmlEscaped())</dc:description>" } ?? "")
            \(metadata.rights.map { "<dc:rights>\($0.xmlEscaped())</dc:rights>" } ?? "")
            \(editable.preservedMetadataEntries.joined(separator: "\n        "))
          </metadata>
          <manifest>
            \(manifestItems.joined(separator: "\n    "))
          </manifest>
          <spine\(tocAttr)>
            \(spineItems)
          </spine>
        </package>
        """
    }

    private static func buildNav(editable: EditablePublication) -> String {
        let tocItems: [NavigationItem]
        let pageItems: [NavigationItem]
        let landmarks: [NavigationItem]
        if let override = editable.navigationOverride {
            let autoTOC = editable.chapters.map { NavigationItem(label: $0.title, href: $0.href) }
            let autoPage = editable.chapters.enumerated().map { idx, chapter in
                NavigationItem(label: "Page \(idx + 1)", href: chapter.href)
            }
            let autoLandmarks = editable.chapters.first.map { [NavigationItem(label: "Start", href: $0.href)] } ?? []
            tocItems = override.toc.isEmpty ? autoTOC : override.toc
            pageItems = override.pageList.isEmpty ? autoPage : override.pageList
            landmarks = override.landmarks.isEmpty ? autoLandmarks : override.landmarks
        } else {
            tocItems = editable.chapters.map { NavigationItem(label: $0.title, href: $0.href) }
            pageItems = editable.chapters.enumerated().map { idx, chapter in
                NavigationItem(label: "Page \(idx + 1)", href: chapter.href)
            }
            landmarks = editable.chapters.first.map { [NavigationItem(label: "Start", href: $0.href)] } ?? []
        }

        let tocList = renderNavigationList(tocItems, indent: "      ")
        let landmarkList = renderNavigationList(landmarks, indent: "      ")
        let pageList = renderNavigationList(pageItems, indent: "      ")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
          <title>Navigation</title>
        </head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>Table of Contents</h1>
            <ol>
              \(tocList)
            </ol>
          </nav>
          <nav epub:type="landmarks" id="landmarks">
            <h2>Landmarks</h2>
            <ol>
              \(landmarkList)
            </ol>
          </nav>
          <nav epub:type="page-list" id="page-list">
            <h2>Pages</h2>
            <ol>
              \(pageList)
            </ol>
          </nav>
        </body>
        </html>
        """
    }

    private static func renderNavigationList(_ items: [NavigationItem], indent: String) -> String {
        items.map { item in
            if item.children.isEmpty {
                return #"\#(indent)<li><a href="\#(item.href.xmlEscaped())">\#(item.label.xmlEscaped())</a></li>"#
            }
            let nested = renderNavigationList(item.children, indent: indent + "  ")
            return """
            \(indent)<li>
            \(indent)  <a href="\(item.href.xmlEscaped())">\(item.label.xmlEscaped())</a>
            \(indent)  <ol>
            \(nested)
            \(indent)  </ol>
            \(indent)</li>
            """
        }.joined(separator: "\n")
    }

    private static func buildNCX(editable: EditablePublication) -> String {
        let navPoints = editable.chapters.enumerated().map { idx, chapter in
            """
            <navPoint id="navPoint-\(idx + 1)" playOrder="\(idx + 1)">
              <navLabel><text>\(chapter.title.xmlEscaped())</text></navLabel>
              <content src="\(chapter.href.xmlEscaped())"/>
            </navPoint>
            """
        }.joined(separator: "\n    ")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(editable.metadata.identifier.xmlEscaped())"/>
          </head>
          <docTitle><text>\(editable.metadata.title.xmlEscaped())</text></docTitle>
          <navMap>
            \(navPoints)
          </navMap>
        </ncx>
        """
    }
}

private enum OPFMetadataPreserver {
    static func extractUnknownMetadataEntries(fromOPF opf: String) -> [String] {
        guard
            let metadataRegex = try? NSRegularExpression(pattern: #"<metadata\b[^>]*>([\s\S]*?)</metadata>"#, options: [.caseInsensitive]),
            let metadataMatch = metadataRegex.firstMatch(in: opf, options: [], range: NSRange(location: 0, length: opf.utf16.count)),
            let metadataRange = Range(metadataMatch.range(at: 1), in: opf)
        else {
            return []
        }
        let metadataBlock = String(opf[metadataRange])
        guard let nodeRegex = try? NSRegularExpression(
            pattern: #"<([A-Za-z0-9:_-]+)([^>]*)>([\s\S]*?)</\1>|<([A-Za-z0-9:_-]+)([^>]*)/>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let matches = nodeRegex.matches(in: metadataBlock, options: [], range: NSRange(location: 0, length: metadataBlock.utf16.count))
        return matches.compactMap { match in
            let name: String?
            let attrs: String
            let content: String?
            if let r = Range(match.range(at: 1), in: metadataBlock) {
                name = String(metadataBlock[r])
                attrs = Range(match.range(at: 2), in: metadataBlock).map { String(metadataBlock[$0]) } ?? ""
                content = Range(match.range(at: 3), in: metadataBlock).map { String(metadataBlock[$0]) }
            } else if let r = Range(match.range(at: 4), in: metadataBlock) {
                name = String(metadataBlock[r])
                attrs = Range(match.range(at: 5), in: metadataBlock).map { String(metadataBlock[$0]) } ?? ""
                content = nil
            } else {
                return nil
            }
            guard let name else { return nil }
            if isKnownMetadataElement(name: name, attrs: attrs) {
                return nil
            }
            if let content {
                return "<\(name)\(attrs)>\(content)</\(name)>"
            }
            return "<\(name)\(attrs)/>"
        }
    }

    private static func isKnownMetadataElement(name: String, attrs: String) -> Bool {
        let localName = name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
        switch localName {
        case "identifier", "title", "creator", "language", "publisher", "description", "rights":
            return true
        case "meta":
            let lower = attrs.lowercased()
            return lower.contains("property=\"dcterms:modified\"") || lower.contains("property='dcterms:modified'")
        default:
            return false
        }
    }
}
