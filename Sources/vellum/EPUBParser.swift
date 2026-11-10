import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Validation policy for authoring or resilient plain-text reading.
public enum EPUBParsingMode: Sendable {
    /// Reject all validation defects; intended for validation and authoring.
    case strict
    /// Recover readable content and record warnings while preserving safety checks.
    case lenient
}

/// Parses EPUB archives into validated models, optionally recovering reading defects.
public struct EPUBParser: Sendable {
    private let mode: EPUBParsingMode

    /// Creates an EPUB parser.
    ///
    /// - Parameter mode: Strict validation by default; lenient mode records recoverable warnings.
    public init(mode: EPUBParsingMode = .strict) {
        self.mode = mode
    }

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

        return try parseExtractedEPUB(at: temp)
    }

    /// Parses an EPUB whose package contents have already been extracted to a directory.
    ///
    /// - Parameter root: Directory containing the `mimetype` file and `META-INF/container.xml`.
    /// - Returns: A validated ``EPUBBook``.
    /// - Throws: ``VellumError`` when validation or I/O fails.
    func parseExtractedEPUB(at root: URL) throws -> EPUBBook {
        var warnings: [VellumDiagnostic] = []
        let mimetypeURL = root.appendingPathComponent("mimetype")
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

        let containerURL = root.appendingPathComponent(Internal.containerPath)
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
        let opfURL = root.appendingPathComponent(EPUBHref.path(opfPath))

        let encryptionURL = root.appendingPathComponent("META-INF/encryption.xml")
        let encryption = FileManager.default.fileExists(atPath: encryptionURL.path)
            ? try EPUBEncryption.read(at: encryptionURL) : []
        // Check the OPF before trying to parse potentially encrypted bytes.
        try EPUBEncryption.rejectRequiredDocuments(encryption, paths: [EPUBHref.path(opfPath)])

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
            spineTOCID: parsed.spineTOCID,
            warnings: &warnings
        )
        try validateUnsupportedFeatures(manifest: parsed.manifest)

        let opfBase = opfURL.deletingLastPathComponent()
        let requiredItems = parsed.manifest.filter { item in
            item.properties.contains("nav") || item.mediaType == "application/x-dtbncx+xml"
                || parsed.spine.contains(where: { $0.idref == item.id })
        }
        let packageDirectory = EPUBHref.path(opfPath).split(separator: "/").dropLast().joined(separator: "/")
        let requiredPaths = Set(requiredItems.map { EPUBHref.normalizePath(packageDirectory + "/" + EPUBHref.path($0.href)) })
        try EPUBEncryption.rejectRequiredDocuments(encryption, paths: requiredPaths)
        try validateManifestResourcesExist(parsed.manifest, opfBase: opfBase, warnings: &warnings)
        let navItem = parsed.manifest.first(where: { $0.properties.contains("nav") })
        let ncxItem = parsed.manifest.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
        var toc: [EPUBTOCNode] = []
        if let navItem {
            toc = try readNavigation(navItem, opfBase: opfBase, manifest: parsed.manifest, warnings: &warnings)
        }
        // Lenient reading can use the NCX when nav.xhtml is absent or broken.
        if toc.isEmpty, let ncxItem {
            toc = try readNavigation(ncxItem, opfBase: opfBase, manifest: parsed.manifest, warnings: &warnings)
        }
        if navItem == nil, ncxItem == nil {
            try record([
                .init(
                    code: "PAR004",
                    specRule: "EPUB Navigation",
                    filePath: opfPath,
                    message: "No navigation document found (nav.xhtml or NCX).",
                    hint: "Include a nav item (EPUB3) or NCX item (EPUB2 compatibility)."
                )
            ], warnings: &warnings)
        }
        try validateTOCPathSafety(toc, opfPath: opfPath)
        try validateTOCTargets(toc, manifest: parsed.manifest, filePath: navItem?.href ?? ncxItem?.href ?? opfPath, warnings: &warnings)

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
                try record([
                    .init(
                        code: "PAR023",
                        specRule: "EPUB Spine Content Document Type",
                        filePath: manifestItem.href,
                        message: "Spine item \(spineItem.idref) does not reference XHTML content.",
                        hint: "Spine entries must reference application/xhtml+xml documents."
                    )
                ], warnings: &warnings)
                chapters.append(placeholder(for: manifestItem, toc: toc))
                continue
            }

            let chapterURL = opfBase.appendingPathComponent(EPUBHref.path(manifestItem.href))
            if mode == .lenient, !FileManager.default.fileExists(atPath: chapterURL.path) {
                // PAR025 was recorded during manifest validation.
                chapters.append(placeholder(for: manifestItem, toc: toc))
                continue
            }
            let chapterXHTML = try EPUBDocumentText.read(at: chapterURL)
            try validateXMLWellFormed(chapterXHTML, filePath: manifestItem.href, code: "PAR029", specRule: "EPUB Content XML Well-formedness", warnings: &warnings)
            if !chapterXHTML.contains("<html") || !chapterXHTML.contains("<body") {
                try record([
                    .init(
                        code: "PAR012",
                        specRule: "EPUB Content Document Structure",
                        filePath: manifestItem.href,
                        message: "Chapter is missing required html/body structure.",
                        hint: "Ensure each XHTML content document includes <html> and <body>."
                    )
                ], warnings: &warnings)
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
            chapters: chapters,
            coverItemID: parsed.coverItemID,
            coverGuideHref: parsed.guideCoverHref,
            diagnostics: warnings,
            stylesheets: readStylesheets(parsed.manifest, opfBase: opfBase)
        )
    }

    /// The manifest's CSS, capped so a pathological package can't bloat the
    /// parsed book (real stylesheets are a few to tens of kilobytes).
    private func readStylesheets(_ manifest: [EPUBManifestItem], opfBase: URL) -> [String: String] {
        var sheets: [String: String] = [:]
        var total = 0
        for item in manifest where item.mediaType.lowercased() == "text/css" {
            let url = opfBase.appendingPathComponent(EPUBHref.path(item.href))
            guard let data = try? Data(contentsOf: url), data.count <= 512 * 1024, total + data.count <= 2 * 1024 * 1024,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            sheets[item.href] = text
            total += data.count
        }
        return sheets
    }

    // MARK: - Reading recovery

    private func record(_ diagnostics: [VellumDiagnostic], warnings: inout [VellumDiagnostic]) throws {
        guard !diagnostics.isEmpty else { return }
        guard mode == .lenient else { throw VellumError.strictValidationFailed(diagnostics) }
        warnings += diagnostics.map {
            VellumDiagnostic(code: $0.code, severity: .warning, specRule: $0.specRule, filePath: $0.filePath, message: $0.message, hint: $0.hint)
        }
    }

    private func placeholder(for item: EPUBManifestItem, toc: [EPUBTOCNode]) -> EPUBChapter {
        EPUBChapter(
            id: item.id,
            title: NavParser.findLabel(forHref: item.href, toc: toc) ?? item.id,
            href: item.href,
            xhtml: "",
            plainText: "This page can't be displayed."
        )
    }

    private func readNavigation(_ item: EPUBManifestItem, opfBase: URL, manifest: [EPUBManifestItem], warnings: inout [VellumDiagnostic]) throws -> [EPUBTOCNode] {
        let isNCX = item.mediaType == "application/x-dtbncx+xml"
        let code = isNCX ? "PAR028" : "PAR026"
        let text: String
        do {
            text = try EPUBDocumentText.read(at: opfBase.appendingPathComponent(EPUBHref.path(item.href)))
        } catch {
            guard mode == .lenient else { throw error }
            try record([.init(code: code, specRule: "EPUB Navigation Readability", filePath: item.href,
                              message: "Unable to read navigation document.", hint: "Provide a readable UTF-8 or UTF-16 navigation document.")], warnings: &warnings)
            return []
        }
        try validateXMLWellFormed(text, filePath: item.href, code: code, specRule: "EPUB Navigation XML Well-formedness", warnings: &warnings)
        let toc = isNCX ? NavParser.parseNCX(text, documentHref: item.href, manifest: manifest)
            : NavParser.parseTOC(text, documentHref: item.href, manifest: manifest)
        if toc.isEmpty {
            try record([.init(code: "PAR027", specRule: "EPUB TOC Navigation Semantics", filePath: item.href,
                              message: "Navigation document does not contain a valid table of contents.",
                              hint: "Provide a toc nav section or NCX navMap with labeled links.")], warnings: &warnings)
        }
        return toc
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
        spineTOCID: String?,
        warnings: inout [VellumDiagnostic]
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

        let opfDirectory = EPUBHref.path(opfPath).split(separator: "/").dropLast().joined(separator: "/")
        let unsafeHrefs = manifest.filter { isUnsafeManifestHref($0.href, opfDirectory: opfDirectory) }
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

        if mode == .lenient {
            // These navigation presence rules have a safe empty-TOC/NCX fallback.
            let recoverableCodes: Set<String> = ["PAR022", "PAR039"]
            try record(diagnostics.filter { recoverableCodes.contains($0.code) }, warnings: &warnings)
            diagnostics.removeAll { recoverableCodes.contains($0.code) }
        }
        if !diagnostics.isEmpty {
            throw VellumError.strictValidationFailed(diagnostics)
        }
    }

    private func validateXMLWellFormed(_ xml: String, filePath: String, code: String, specRule: String, warnings: inout [VellumDiagnostic]) throws {
        let parser = XMLParser(data: EPUBDocumentText.parserData(from: xml))
        let parsedSuccessfully = parser.parse()
        guard parsedSuccessfully, parser.parserError == nil else {
            try record([
                .init(
                    code: code,
                    specRule: specRule,
                    filePath: filePath,
                    message: "XML document is not well-formed.",
                    hint: "Fix malformed tags/attributes and ensure valid XML structure."
                )
            ], warnings: &warnings)
            return
        }
    }

    private func validateTOCPathSafety(_ toc: [EPUBTOCNode], opfPath: String) throws {
        let directory = EPUBHref.path(opfPath).split(separator: "/").dropLast().joined(separator: "/")
        let unsafe = toc.contains { node in
            guard !EPUBHref.hasScheme(node.href) else { return false }
            let decoded = node.href.removingPercentEncoding ?? node.href
            let rootRelative = EPUBHref.normalizePath(directory + "/" + EPUBHref.path(node.href))
            return decoded.hasPrefix("/") || decoded.hasPrefix("\\") || decoded.contains("\0")
                || rootRelative == ".." || rootRelative.hasPrefix("../")
        }
        if unsafe {
            throw VellumError.strictValidationFailed([.init(
                code: "PAR030", specRule: "EPUB Resource Path Safety", filePath: opfPath,
                message: "Navigation contains a path outside the EPUB package.", hint: "Use navigation links within the package."
            )])
        }
    }

    private func validateTOCTargets(_ toc: [EPUBTOCNode], manifest: [EPUBManifestItem], filePath: String, warnings: inout [VellumDiagnostic]) throws {
        guard !toc.isEmpty else { return }
        let hrefs = Set(manifest.map { EPUBHref.path($0.href) })
        // External TOC links are retained but are never local reading targets.
        // They do not invalidate an otherwise readable book in strict mode.
        let broken = toc.filter { !EPUBHref.hasScheme($0.href) && !hrefs.contains(EPUBHref.path($0.href)) }
        if !broken.isEmpty {
            try record([
                .init(
                    code: "PAR024",
                    specRule: "EPUB Navigation Target Validity",
                    filePath: filePath,
                    message: "Navigation contains href(s) not present in manifest.",
                    hint: "Ensure each TOC href points to a manifest resource."
                )
            ], warnings: &warnings)
        }
    }

    private func validateManifestResourcesExist(_ manifest: [EPUBManifestItem], opfBase: URL, warnings: inout [VellumDiagnostic]) throws {
        let missing = manifest.filter { item in
            if item.href.hasPrefix("http://") || item.href.hasPrefix("https://") {
                return false
            }
            return !FileManager.default.fileExists(atPath: opfBase.appendingPathComponent(EPUBHref.path(item.href)).path)
        }
        if !missing.isEmpty {
            try record(missing.map { item in
                .init(
                    code: "PAR025",
                    specRule: "EPUB Manifest Resource Presence",
                    filePath: item.href,
                    message: "Manifest references file(s) that do not exist in the EPUB package.",
                    hint: "Ensure every manifest href points to an included package resource."
                )
            }, warnings: &warnings)
        }
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
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") || decoded.hasPrefix("\\") || decoded.contains("\0") || EPUBHref.hasScheme(decoded) { return true }
        let normalized = decoded.replacingOccurrences(of: "\\", with: "/")
        if normalized.contains("../") || normalized.hasPrefix("..") { return true }
        return false
    }

    /// Manifest hrefs are relative to the OPF, so `../js/kobo.js` from
    /// `OEBPS/` (every Kobo EPUB has it) is the in-package `js/kobo.js`. Only
    /// a path that leaves the package root is unsafe, the same rule as
    /// `validateTOCPathSafety`. Readers resolve an href both percent-decoded
    /// (this parser) and as spelled (`OpenedPublication`), and the two can
    /// differ (`a%2fb/../../../x`), so both readings must stay inside.
    private func isUnsafeManifestHref(_ href: String, opfDirectory: String) -> Bool {
        let decoded = href.removingPercentEncoding ?? href
        if decoded.hasPrefix("/") || decoded.hasPrefix("\\") || decoded.contains("\0") || EPUBHref.hasScheme(decoded) {
            return true
        }
        let spelled = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return [EPUBHref.path(href), spelled].contains { path in
            let rootRelative = EPUBHref.normalizePath(opfDirectory + "/" + path)
            return rootRelative == ".." || rootRelative.hasPrefix("../")
        }
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
        var legacyCoverItemID: String?
        var guideCoverHref: String?

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
                if attributeDict["name"] == "cover" {
                    legacyCoverItemID = attributeDict["content"]
                }
            } else if elementName == "reference" {
                currentMetaProperty = nil
                currentIdentifierID = nil
                if attributeDict["type"] == "cover" {
                    guideCoverHref = attributeDict["href"]
                }
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
        spineTOCID: String?,
        coverItemID: String?,
        guideCoverHref: String?
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
        return (
            metadata,
            delegate.manifest,
            delegate.spine,
            delegate.packageVersion ?? "3.0",
            delegate.spineTOCID,
            delegate.legacyCoverItemID,
            delegate.guideCoverHref
        )
    }
}

private enum NavParser {
    static func parseTOC(_ navXHTML: String, documentHref: String, manifest: [EPUBManifestItem]) -> [EPUBTOCNode] {
        let parser = XMLParser(data: EPUBDocumentText.parserData(from: navXHTML))
        let delegate = TOCDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return resolve(delegate.nodes, documentHref: documentHref, manifest: manifest)
    }

    static func findLabel(forHref href: String, toc: [EPUBTOCNode]) -> String? {
        toc.first(where: { EPUBHref.path($0.href) == EPUBHref.path(href) })?.label
    }

    static func parseNCX(_ ncx: String, documentHref: String, manifest: [EPUBManifestItem]) -> [EPUBTOCNode] {
        let parser = XMLParser(data: EPUBDocumentText.parserData(from: ncx))
        let delegate = NCXDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return resolve(delegate.nodes, documentHref: documentHref, manifest: manifest)
    }

    private static func resolve(_ nodes: [EPUBTOCNode], documentHref: String, manifest: [EPUBManifestItem]) -> [EPUBTOCNode] {
        nodes.map {
            EPUBTOCNode(label: $0.label, href: EPUBHref.resolve($0.href, relativeTo: documentHref, manifest: manifest), level: $0.level)
        }
    }

    private final class NCXDelegate: NSObject, XMLParserDelegate {
        private struct Point {
            var label = ""
            var href = ""
            let level: Int
        }
        private var points: [Point] = []
        private var stack: [Int] = []
        private var inNavMap = false
        private var inLabel = false
        private var inText = false

        var nodes: [EPUBTOCNode] {
            points.compactMap { point in
                let label = point.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, !point.href.isEmpty else { return nil }
                return EPUBTOCNode(label: label, href: point.href, level: point.level)
            }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "navMap" { inNavMap = true }
            guard inNavMap else { return }
            switch name {
            case "navPoint":
                points.append(Point(level: stack.count))
                stack.append(points.count - 1)
            case "navLabel": inLabel = true
            case "text" where inLabel: inText = true
            case "content":
                if let index = stack.last { points[index].href = attributes["src"] ?? "" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText, let index = stack.last { points[index].label += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            switch name {
            case "navMap": inNavMap = false
            case "navPoint": if !stack.isEmpty { stack.removeLast() }
            case "navLabel": inLabel = false
            case "text": inText = false
            default: break
            }
        }
    }

    private final class TOCDelegate: NSObject, XMLParserDelegate {
        private(set) var nodes: [EPUBTOCNode] = []
        private var navDepth = 0
        private var listDepth = 0
        private var itemDepth = 0
        private var currentLevel = 0
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
                listDepth = 0
                itemDepth = 0
                return
            }
            if navDepth > 0 {
                if normalizedName == "nav" {
                    navDepth += 1
                } else if normalizedName == "ol" {
                    listDepth += 1
                } else if normalizedName == "li" {
                    itemDepth += 1
                } else if normalizedName == "a" {
                    currentLevel = max(0, max(listDepth, itemDepth) - 1)
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
                        nodes.append(EPUBTOCNode(label: label, href: href, level: currentLevel))
                    }
                }
                currentHref = nil
                currentLabel = ""
            }
            if navDepth > 0, normalizedName == "ol" { listDepth -= 1 }
            if navDepth > 0, normalizedName == "li" { itemDepth -= 1 }
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
