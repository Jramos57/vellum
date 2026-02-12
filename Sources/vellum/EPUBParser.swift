import Foundation

/// Parses EPUB archives into strict, validated models.
public struct EPUBParser: Sendable {
    /// Creates an EPUB parser.
    public init() {}

    /// Parses an EPUB from disk.
    ///
    /// - Parameter epubURL: EPUB archive URL.
    /// - Returns: A validated ``EPUBBook``.
    /// - Throws: ``VellumError`` when validation or I/O fails.
    public func parseEPUB(at epubURL: URL) throws -> EPUBBook {
        try parseEPUBSync(at: epubURL)
    }

    /// Parses an EPUB from disk.
    ///
    /// - Parameter epubURL: EPUB archive URL.
    /// - Returns: A validated ``EPUBBook``.
    /// - Throws: ``VellumError`` when validation or I/O fails.
    public func parseEPUB(at epubURL: URL) async throws -> EPUBBook {
        try parseEPUBSync(at: epubURL)
    }

    private func parseEPUBSync(at epubURL: URL) throws -> EPUBBook {
        try ZipTool.validateMimetypeConstraints(archiveURL: epubURL)

        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try ZipTool.extractArchive(epubURL, to: temp)

        let mimetypeURL = temp.appendingPathComponent("mimetype")
        let mimetype = try String(contentsOf: mimetypeURL, encoding: .utf8)
        guard mimetype == "application/epub+zip" else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR001",
                    specRule: "EPUB OCF mimetype",
                    filePath: "mimetype",
                    message: "Invalid mimetype file content.",
                    hint: "mimetype must contain exactly application/epub+zip."
                )
            ])
        }

        let containerURL = temp.appendingPathComponent(Internal.containerPath)
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR002",
                    specRule: "EPUB OCF Container",
                    filePath: Internal.containerPath,
                    message: "Missing container.xml.",
                    hint: "Provide META-INF/container.xml with a rootfile path."
                )
            ])
        }

        let containerData = try Data(contentsOf: containerURL)
        let rootfile = try ContainerParser.parseRootfile(containerData)
        let opfPath = rootfile.path
        if rootfile.mediaType != "application/oebps-package+xml" {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR037",
                    specRule: "EPUB Container Rootfile Media Type",
                    filePath: Internal.containerPath,
                    message: "container.xml rootfile media-type is invalid.",
                    hint: "Set rootfile media-type to application/oebps-package+xml."
                )
            ])
        }
        try validateContainerPathSafety(opfPath)
        let opfURL = temp.appendingPathComponent(opfPath)

        let encryptionURL = temp.appendingPathComponent("META-INF/encryption.xml")
        if FileManager.default.fileExists(atPath: encryptionURL.path) {
            throw VellumError.unsupportedFeature(
                "Encrypted/DRM EPUBs are not supported.",
                [
                    .init(
                        code: "PAR020",
                        specRule: "EPUB OCF Encryption",
                        filePath: "META-INF/encryption.xml",
                        message: "encryption.xml detected.",
                        hint: "Use a non-encrypted EPUB source."
                    )
                ]
            )
        }

        guard FileManager.default.fileExists(atPath: opfURL.path) else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR003",
                    specRule: "EPUB Package Document Location",
                    filePath: opfPath,
                    message: "Referenced OPF file does not exist.",
                    hint: "Ensure container.xml rootfile full-path points to a valid OPF."
                )
            ])
        }

        let opfData = try Data(contentsOf: opfURL)
        let parsed = try OPFParser.parse(opfData)
        try validateManifestAndSpine(
            parsed.manifest,
            parsed.spine,
            opfPath: opfPath,
            packageVersion: parsed.packageVersion,
            spineTOCID: parsed.spineTOCID
        )
        try validateUnsupportedFeatures(manifest: parsed.manifest)

        let opfBase = opfURL.deletingLastPathComponent()
        try validateManifestResourcesExist(parsed.manifest, opfBase: opfBase, opfPath: opfPath)
        let navItem = parsed.manifest.first(where: { $0.properties.contains("nav") })
        let ncxItem = parsed.manifest.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
        let toc: [EPUBTOCNode]
        if let navItem {
            let navURL = opfBase.appendingPathComponent(navItem.href)
            let navText = try String(contentsOf: navURL, encoding: .utf8)
            try validateXMLWellFormed(navText, filePath: navItem.href, code: "PAR026", specRule: "EPUB Navigation XML Well-formedness")
            toc = NavParser.parseTOC(navText)
            if toc.isEmpty {
                throw VellumError.strictValidationFailed([
                    .init(
                        code: "PAR027",
                        specRule: "EPUB TOC Navigation Semantics",
                        filePath: navItem.href,
                        message: "Navigation document does not contain a valid toc nav section.",
                        hint: "Ensure nav.xhtml has <nav epub:type=\"toc\"> with at least one anchor."
                    )
                ])
            }
        } else if let ncxItem {
            if parsed.packageVersion.hasPrefix("3.") {
                throw VellumError.strictValidationFailed([
                    .init(
                        code: "PAR039",
                        specRule: "EPUB 3 Navigation Requirement",
                        filePath: opfPath,
                        message: "EPUB 3 package is missing nav.xhtml navigation document.",
                        hint: "Include exactly one manifest item with properties=\"nav\"."
                    )
                ])
            }
            let ncxURL = opfBase.appendingPathComponent(ncxItem.href)
            let ncx = try String(contentsOf: ncxURL, encoding: .utf8)
            try validateXMLWellFormed(ncx, filePath: ncxItem.href, code: "PAR028", specRule: "EPUB NCX XML Well-formedness")
            toc = NavParser.parseNCX(ncx)
        } else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR004",
                    specRule: "EPUB Navigation",
                    filePath: opfPath,
                    message: "No navigation document found (nav.xhtml or NCX).",
                    hint: "Include a nav item (EPUB3) or NCX item (EPUB2 compatibility)."
                )
            ])
        }
        try validateTOCTargets(toc, manifest: parsed.manifest, opfPath: opfPath)

        var chapters: [EPUBChapter] = []
        for spineItem in parsed.spine {
            guard let manifestItem = parsed.manifest.first(where: { $0.id == spineItem.idref }) else {
                throw VellumError.strictValidationFailed([
                    .init(
                        code: "PAR005",
                        specRule: "EPUB Spine/Manifest Referential Integrity",
                        filePath: opfPath,
                        message: "Spine references missing manifest item \(spineItem.idref).",
                        hint: "Ensure each <itemref idref> maps to a manifest <item id>."
                    )
                ])
            }
            if manifestItem.mediaType != "application/xhtml+xml" {
                throw VellumError.strictValidationFailed([
                    .init(
                        code: "PAR023",
                        specRule: "EPUB Spine Content Document Type",
                        filePath: opfPath,
                        message: "Spine item \(spineItem.idref) does not reference XHTML content.",
                        hint: "Spine entries must reference application/xhtml+xml documents."
                    )
                ])
            }

            let chapterURL = opfBase.appendingPathComponent(manifestItem.href)
            let chapterXHTML = try String(contentsOf: chapterURL, encoding: .utf8)
            try validateXMLWellFormed(chapterXHTML, filePath: manifestItem.href, code: "PAR029", specRule: "EPUB Content XML Well-formedness")
            if !chapterXHTML.contains("<html") || !chapterXHTML.contains("<body") {
                throw VellumError.strictValidationFailed([
                    .init(
                        code: "PAR012",
                        specRule: "EPUB Content Document Structure",
                        filePath: manifestItem.href,
                        message: "Chapter is missing required html/body structure.",
                        hint: "Ensure each XHTML content document includes <html> and <body>."
                    )
                ])
            }
            let chapterTitle = NavParser.findLabel(forHref: manifestItem.href, toc: toc) ?? manifestItem.id
            let chapter = EPUBChapter(
                id: manifestItem.id,
                title: chapterTitle,
                href: manifestItem.href,
                xhtml: chapterXHTML,
                plainText: MarkdownConverter.plainText(fromXHTML: chapterXHTML)
            )
            chapters.append(chapter)
        }

        return EPUBBook(
            metadata: parsed.metadata,
            manifest: parsed.manifest,
            spine: parsed.spine,
            toc: toc,
            chapters: chapters
        )
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func validateUnsupportedFeatures(manifest: [EPUBManifestItem]) throws {
        let encrypted = manifest.filter { $0.mediaType.contains("vnd.adobe") || $0.mediaType.contains("drm") }
        if !encrypted.isEmpty {
            throw VellumError.unsupportedFeature("DRM and encrypted EPUB content is not supported.")
        }
    }

    private func validateManifestAndSpine(
        _ manifest: [EPUBManifestItem],
        _ spine: [EPUBSpineItem],
        opfPath: String,
        packageVersion: String,
        spineTOCID: String?
    ) throws {
        var diagnostics: [VellumDiagnostic] = []

        let emptyManifestItems = manifest.filter { $0.id.isEmpty || $0.href.isEmpty || $0.mediaType.isEmpty }
        if !emptyManifestItems.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR013",
                    specRule: "EPUB Manifest Item Completeness",
                    filePath: opfPath,
                    message: "Manifest contains item(s) missing id, href, or media-type.",
                    hint: "Each manifest item must include id, href, and media-type."
                )
            )
        }
        let invalidMediaTypeItems = manifest.filter { !isValidMediaType($0.mediaType) }
        if !invalidMediaTypeItems.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR044",
                    specRule: "EPUB Manifest Media Type Syntax",
                    filePath: opfPath,
                    message: "Manifest contains item(s) with invalid media-type syntax.",
                    hint: "Use a valid MIME type in type/subtype format (for example, application/xhtml+xml)."
                )
            )
        }

        let duplicateManifestIDs = Dictionary(grouping: manifest, by: \.id).filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !duplicateManifestIDs.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR014",
                    specRule: "EPUB Manifest Unique IDs",
                    filePath: opfPath,
                    message: "Manifest contains duplicate item IDs.",
                    hint: "Ensure each manifest item id is unique."
                )
            )
        }

        let duplicateHrefs = Dictionary(grouping: manifest, by: \.href).filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !duplicateHrefs.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR015",
                    specRule: "EPUB Manifest Unique HREFs",
                    filePath: opfPath,
                    message: "Manifest contains duplicate href values.",
                    hint: "Use unique href values per resource."
                )
            )
        }

        let remoteHrefs = manifest.filter { $0.href.hasPrefix("http://") || $0.href.hasPrefix("https://") }
        if !remoteHrefs.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR021",
                    specRule: "EPUB OCF Resource Location",
                    filePath: opfPath,
                    message: "Manifest contains remote URLs.",
                    hint: "Use package-relative resource href values."
                )
            )
        }

        let unsafeHrefs = manifest.filter { isUnsafePath($0.href) }
        if !unsafeHrefs.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR030",
                    specRule: "EPUB Resource Path Safety",
                    filePath: opfPath,
                    message: "Manifest contains unsafe href path(s).",
                    hint: "Avoid absolute paths and traversal segments in href values."
                )
            )
        }

        let navItems = manifest.filter { $0.properties.contains("nav") }
        let hasNCX = manifest.contains { $0.mediaType == "application/x-dtbncx+xml" }
        let coverImageItems = manifest.filter { $0.properties.contains("cover-image") }
        if coverImageItems.count > 1 {
            diagnostics.append(
                .init(
                    code: "PAR034",
                    specRule: "EPUB Cover Image Uniqueness",
                    filePath: opfPath,
                    message: "Manifest contains multiple cover-image properties.",
                    hint: "Mark at most one manifest item as cover-image."
                )
            )
        }
        if navItems.count > 1 {
            diagnostics.append(
                .init(
                    code: "PAR016",
                    specRule: "EPUB Navigation Uniqueness",
                    filePath: opfPath,
                    message: "Manifest contains multiple nav items.",
                    hint: "Use exactly one nav item."
                )
            )
        }
        if navItems.isEmpty && !hasNCX {
            diagnostics.append(
                .init(
                    code: "PAR022",
                    specRule: "EPUB Navigation Presence",
                    filePath: opfPath,
                    message: "Manifest has neither nav document nor NCX.",
                    hint: "Provide nav.xhtml (EPUB3) or toc.ncx (EPUB2 compatibility)."
                )
            )
        }
        if packageVersion.hasPrefix("3.") && navItems.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR039",
                    specRule: "EPUB 3 Navigation Requirement",
                    filePath: opfPath,
                    message: "EPUB 3 package requires nav.xhtml navigation document.",
                    hint: "Add a manifest item with properties=\"nav\" and media-type=\"application/xhtml+xml\"."
                )
            )
        }
        if let nav = navItems.first, nav.mediaType != "application/xhtml+xml" {
            diagnostics.append(
                .init(
                    code: "PAR017",
                    specRule: "EPUB Navigation Media Type",
                    filePath: opfPath,
                    message: "Nav item must use application/xhtml+xml media type.",
                    hint: "Set nav media-type to application/xhtml+xml."
                )
            )
        }
        if packageVersion == "2.0" {
            let ncxItems = manifest.filter { $0.mediaType == "application/x-dtbncx+xml" }
            if ncxItems.isEmpty {
                diagnostics.append(
                    .init(
                        code: "PAR042",
                        specRule: "EPUB 2 NCX Requirement",
                        filePath: opfPath,
                        message: "EPUB 2 package is missing an NCX manifest item.",
                        hint: "Add a manifest item with media-type application/x-dtbncx+xml."
                    )
                )
            }
            if let spineTOCID, !spineTOCID.isEmpty {
                if !manifest.contains(where: { $0.id == spineTOCID && $0.mediaType == "application/x-dtbncx+xml" }) {
                    diagnostics.append(
                        .init(
                            code: "PAR043",
                            specRule: "EPUB 2 Spine TOC Reference",
                            filePath: opfPath,
                            message: "spine toc attribute does not reference an NCX manifest item.",
                            hint: "Set spine toc to the id of the NCX manifest item."
                        )
                    )
                }
            } else {
                diagnostics.append(
                    .init(
                        code: "PAR043",
                        specRule: "EPUB 2 Spine TOC Reference",
                        filePath: opfPath,
                        message: "EPUB 2 package is missing spine toc reference.",
                        hint: "Set spine toc to the id of the NCX manifest item."
                    )
                )
            }
        }

        let manifestIDs = Set(manifest.map(\.id))
        let brokenSpineRefs = spine.filter { !manifestIDs.contains($0.idref) }
        if !brokenSpineRefs.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR018",
                    specRule: "EPUB Spine Referential Integrity",
                    filePath: opfPath,
                    message: "Spine contains idref(s) not present in manifest.",
                    hint: "Each spine idref must reference an existing manifest item id."
                )
            )
        }

        let duplicateSpineRefs = Dictionary(grouping: spine, by: \.idref).filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !duplicateSpineRefs.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR019",
                    specRule: "EPUB Spine Uniqueness",
                    filePath: opfPath,
                    message: "Spine contains duplicate idref values.",
                    hint: "Each primary spine entry should be unique in strict mode."
                )
            )
        }

        let invalidOverlayRefs = manifest.filter { item in
            guard let overlay = item.mediaOverlay, !overlay.isEmpty else { return false }
            return !manifestIDs.contains(overlay)
        }
        if !invalidOverlayRefs.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR035",
                    specRule: "EPUB Media Overlay Reference",
                    filePath: opfPath,
                    message: "Manifest item has media-overlay reference to missing item.",
                    hint: "Set media-overlay to an existing manifest item id."
                )
            )
        }
        let nonSMILOverlayRefs = manifest.filter { item in
            guard let overlay = item.mediaOverlay, !overlay.isEmpty else { return false }
            guard let overlayItem = manifest.first(where: { $0.id == overlay }) else { return false }
            return overlayItem.mediaType != "application/smil+xml"
        }
        if !nonSMILOverlayRefs.isEmpty {
            diagnostics.append(
                .init(
                    code: "PAR036",
                    specRule: "EPUB Media Overlay Media Type",
                    filePath: opfPath,
                    message: "media-overlay reference must point to application/smil+xml item.",
                    hint: "Ensure overlay target item has media-type application/smil+xml."
                )
            )
        }

        if !diagnostics.isEmpty {
            throw VellumError.strictValidationFailed(diagnostics)
        }
    }

    private func validateXMLWellFormed(_ xml: String, filePath: String, code: String, specRule: String) throws {
        guard let data = xml.data(using: .utf8) else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: code,
                    specRule: specRule,
                    filePath: filePath,
                    message: "Unable to decode XML text as UTF-8.",
                    hint: "Ensure document is UTF-8 encoded."
                )
            ])
        }
        let parser = XMLParser(data: data)
        if !parser.parse() {
            throw VellumError.strictValidationFailed([
                .init(
                    code: code,
                    specRule: specRule,
                    filePath: filePath,
                    message: "XML document is not well-formed.",
                    hint: "Fix malformed tags/attributes and ensure valid XML structure."
                )
            ])
        }
    }

    private func validateTOCTargets(_ toc: [EPUBTOCNode], manifest: [EPUBManifestItem], opfPath: String) throws {
        guard !toc.isEmpty else { return }
        let hrefs = Set(manifest.map { normalizeHref($0.href) })
        let broken = toc.filter { !hrefs.contains(normalizeHref($0.href)) }
        if !broken.isEmpty {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR024",
                    specRule: "EPUB Navigation Target Validity",
                    filePath: opfPath,
                    message: "Navigation contains href(s) not present in manifest.",
                    hint: "Ensure each TOC href points to a manifest resource."
                )
            ])
        }
    }

    private func validateManifestResourcesExist(_ manifest: [EPUBManifestItem], opfBase: URL, opfPath: String) throws {
        let missing = manifest.filter { item in
            if item.href.hasPrefix("http://") || item.href.hasPrefix("https://") {
                return false
            }
            return !FileManager.default.fileExists(atPath: opfBase.appendingPathComponent(item.href).path)
        }
        if !missing.isEmpty {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR025",
                    specRule: "EPUB Manifest Resource Presence",
                    filePath: opfPath,
                    message: "Manifest references file(s) that do not exist in the EPUB package.",
                    hint: "Ensure every manifest href points to an included package resource."
                )
            ])
        }
    }

    private func normalizeHref(_ href: String) -> String {
        String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(href))
    }

    private func validateContainerPathSafety(_ opfPath: String) throws {
        if isUnsafePath(opfPath) {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR031",
                    specRule: "EPUB Container Rootfile Path Safety",
                    filePath: Internal.containerPath,
                    message: "container.xml rootfile path is unsafe.",
                    hint: "Use a package-relative OPF path without absolute or traversal segments."
                )
            ])
        }
    }

    private func isUnsafePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\") { return true }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.contains("../") || normalized.hasPrefix("..") { return true }
        return false
    }

    private func isValidMediaType(_ mediaType: String) -> Bool {
        let parts = mediaType.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let token = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy { token.contains($0) }
        }
    }
}

private enum ContainerParser {
    struct Rootfile {
        let path: String
        let mediaType: String
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var rootfilePath: String?
        var rootfileMediaType: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String : String] = [:]
        ) {
            if elementName == "rootfile" {
                rootfilePath = attributeDict["full-path"]
                rootfileMediaType = attributeDict["media-type"]
            }
        }
    }

    static func parseRootfile(_ data: Data) throws -> Rootfile {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse(), let path = delegate.rootfilePath, !path.isEmpty else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR006",
                    specRule: "EPUB OCF Container rootfile",
                    filePath: Internal.containerPath,
                    message: "Failed to parse rootfile full-path from container.xml.",
                    hint: "container.xml must include rootfile full-path."
                )
            ])
        }
        return Rootfile(path: path, mediaType: delegate.rootfileMediaType ?? "")
    }
}

private enum OPFParser {
    private final class Delegate: NSObject, XMLParserDelegate {
        var metadata = MetadataAccumulator()
        var manifest: [EPUBManifestItem] = []
        var spine: [EPUBSpineItem] = []
        var currentElement: String?
        var currentText = ""
        var currentMetaProperty: String?
        var currentIdentifierID: String?
        var packageVersion: String?
        var packageUniqueIdentifierRef: String?
        var spineTOCID: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String : String] = [:]
        ) {
            currentElement = elementName
            currentText = ""
            if elementName == "package" {
                packageVersion = attributeDict["version"]
                packageUniqueIdentifierRef = attributeDict["unique-identifier"]
            } else if elementName == "spine" {
                spineTOCID = attributeDict["toc"]
            } else if elementName == "item" {
                let properties = attributeDict["properties"]?.split(separator: " ").map(String.init) ?? []
                manifest.append(
                    EPUBManifestItem(
                        id: attributeDict["id"] ?? "",
                        href: attributeDict["href"] ?? "",
                        mediaType: attributeDict["media-type"] ?? "",
                        properties: properties,
                        mediaOverlay: attributeDict["media-overlay"]
                    )
                )
            } else if elementName == "itemref" {
                spine.append(EPUBSpineItem(idref: attributeDict["idref"] ?? ""))
            } else if elementName == "meta" {
                currentMetaProperty = attributeDict["property"]
                currentIdentifierID = nil
            } else if elementName.split(separator: ":").last == "identifier" || elementName == "identifier" {
                currentIdentifierID = attributeDict["id"]
                currentMetaProperty = nil
            } else {
                currentMetaProperty = nil
                currentIdentifierID = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let normalized = elementName.split(separator: ":").last.map(String.init) ?? elementName
            switch normalized {
            case "identifier":
                metadata.identifier = text
                if let id = currentIdentifierID, !id.isEmpty {
                    metadata.identifiersByID[id] = text
                }
            case "title":
                metadata.title = text
            case "creator":
                metadata.creator = text
            case "language":
                metadata.language = text
                metadata.hasLanguage = true
            case "publisher":
                metadata.publisher = text
            case "description":
                metadata.description = text
            case "rights":
                metadata.rights = text
            case "meta":
                if currentMetaProperty == "dcterms:modified", let date = ISO8601DateFormatter().date(from: text) {
                    metadata.modified = date
                    metadata.hasModified = true
                }
            default:
                break
            }
        }
    }

    private struct MetadataAccumulator {
        var identifier = ""
        var title = ""
        var creator = ""
        var language = "en"
        var modified = Date()
        var hasModified = false
        var hasLanguage = false
        var publisher: String?
        var description: String?
        var rights: String?
        var identifiersByID: [String: String] = [:]
    }

    static func parse(_ data: Data) throws -> (
        metadata: EPUBMetadata,
        manifest: [EPUBManifestItem],
        spine: [EPUBSpineItem],
        packageVersion: String,
        spineTOCID: String?
    ) {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR007",
                    specRule: "EPUB OPF XML Well-formedness",
                    filePath: Internal.opfPath,
                    message: "Failed to parse OPF XML.",
                    hint: "Ensure content.opf is valid XML."
                )
            ])
        }

        var diagnostics: [VellumDiagnostic] = []
        if delegate.metadata.identifier.isEmpty {
            diagnostics.append(.init(code: "PAR008", specRule: "EPUB DC metadata", filePath: Internal.opfPath, message: "Missing dc:identifier.", hint: "Add dc:identifier in OPF metadata."))
        }
        if delegate.metadata.title.isEmpty {
            diagnostics.append(.init(code: "PAR009", specRule: "EPUB DC metadata", filePath: Internal.opfPath, message: "Missing dc:title.", hint: "Add dc:title in OPF metadata."))
        }
        if !delegate.metadata.hasLanguage {
            diagnostics.append(
                .init(
                    code: "PAR040",
                    specRule: "EPUB DC metadata",
                    filePath: Internal.opfPath,
                    message: "Missing dc:language.",
                    hint: "Add dc:language in OPF metadata."
                )
            )
        }
        if delegate.manifest.isEmpty {
            diagnostics.append(.init(code: "PAR010", specRule: "EPUB manifest", filePath: Internal.opfPath, message: "Manifest is empty.", hint: "Add manifest items for all content resources."))
        }
        if delegate.spine.isEmpty {
            diagnostics.append(.init(code: "PAR011", specRule: "EPUB spine", filePath: Internal.opfPath, message: "Spine is empty.", hint: "Add at least one itemref in spine."))
        }
        if let version = delegate.packageVersion {
            let isEPUB3 = version.hasPrefix("3.")
            let valid = version == "2.0" || isEPUB3
            if !valid {
                diagnostics.append(
                    .init(
                        code: "PAR032",
                        specRule: "EPUB Package Version",
                        filePath: Internal.opfPath,
                        message: "Unsupported package version \(version).",
                        hint: "Use package version 2.0 or 3.x."
                    )
                )
            }
            if isEPUB3 && !delegate.metadata.hasModified {
                diagnostics.append(
                    .init(
                        code: "PAR038",
                        specRule: "EPUB 3 Package Metadata Modified",
                        filePath: Internal.opfPath,
                        message: "EPUB 3 package is missing dcterms:modified.",
                        hint: "Include <meta property=\"dcterms:modified\">timestamp</meta> in OPF metadata."
                    )
                )
            }
        } else {
            diagnostics.append(
                .init(
                    code: "PAR032",
                    specRule: "EPUB Package Version",
                    filePath: Internal.opfPath,
                    message: "Package version is missing.",
                    hint: "Set package version to 2.0 or 3.x."
                )
            )
        }
        if let ref = delegate.packageUniqueIdentifierRef, !ref.isEmpty {
            if delegate.metadata.identifiersByID[ref]?.isEmpty ?? true {
                diagnostics.append(
                    .init(
                        code: "PAR033",
                        specRule: "EPUB Package Unique Identifier",
                        filePath: Internal.opfPath,
                        message: "unique-identifier does not match any dc:identifier id.",
                        hint: "Set unique-identifier to an existing dc:identifier @id value."
                    )
                )
            }
        } else {
            diagnostics.append(
                .init(
                    code: "PAR041",
                    specRule: "EPUB Package Unique Identifier",
                    filePath: Internal.opfPath,
                    message: "package unique-identifier attribute is missing.",
                    hint: "Set unique-identifier on package and point it to a dc:identifier @id."
                )
            )
        }
        if !diagnostics.isEmpty {
            throw VellumError.strictValidationFailed(diagnostics)
        }

        let metadata = EPUBMetadata(
            identifier: delegate.metadata.identifier,
            title: delegate.metadata.title,
            creator: delegate.metadata.creator.isEmpty ? "Unknown" : delegate.metadata.creator,
            language: delegate.metadata.language,
            modified: delegate.metadata.modified,
            publisher: delegate.metadata.publisher,
            description: delegate.metadata.description,
            rights: delegate.metadata.rights
        )
        return (metadata, delegate.manifest, delegate.spine, delegate.packageVersion ?? "3.0", delegate.spineTOCID)
    }
}

private enum NavParser {
    static func parseTOC(_ navXHTML: String) -> [EPUBTOCNode] {
        guard let data = navXHTML.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = TOCDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.nodes
    }

    static func findLabel(forHref href: String, toc: [EPUBTOCNode]) -> String? {
        toc.first(where: { $0.href == href })?.label
    }

    static func parseNCX(_ ncx: String) -> [EPUBTOCNode] {
        let pattern = #"<navPoint[^>]*>[\s\S]*?<navLabel>\s*<text>(.*?)</text>\s*</navLabel>[\s\S]*?<content\s+src="([^"]+)""#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        guard let regex else { return [] }
        let range = NSRange(location: 0, length: ncx.utf16.count)
        return regex.matches(in: ncx, options: [], range: range).compactMap { match in
            guard
                let labelRange = Range(match.range(at: 1), in: ncx),
                let hrefRange = Range(match.range(at: 2), in: ncx)
            else { return nil }
            return EPUBTOCNode(label: String(ncx[labelRange]), href: String(ncx[hrefRange]))
        }
    }

    private final class TOCDelegate: NSObject, XMLParserDelegate {
        private(set) var nodes: [EPUBTOCNode] = []
        private var navDepth = 0
        private var currentHref: String?
        private var currentLabel = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String : String] = [:]
        ) {
            let normalizedName = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if normalizedName == "nav", hasTOCToken(attributeDict) {
                navDepth = 1
                return
            }
            if navDepth > 0 {
                if normalizedName == "nav" {
                    navDepth += 1
                } else if normalizedName == "a" {
                    currentHref = attributeDict["href"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    currentLabel = ""
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if navDepth > 0, currentHref != nil {
                currentLabel += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let normalizedName = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if navDepth > 0, normalizedName == "a" {
                if
                    let href = currentHref,
                    !href.isEmpty
                {
                    let label = currentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !label.isEmpty {
                        nodes.append(EPUBTOCNode(label: label, href: href))
                    }
                }
                currentHref = nil
                currentLabel = ""
            }
            if navDepth > 0, normalizedName == "nav" {
                navDepth -= 1
            }
        }

        private func hasTOCToken(_ attributes: [String: String]) -> Bool {
            guard let rawType = attributes.first(where: { key, _ in
                key.split(separator: ":").last == "type"
            })?.value else {
                return false
            }
            return rawType
                .split(whereSeparator: \.isWhitespace)
                .contains(where: { $0 == "toc" })
        }
    }
}
