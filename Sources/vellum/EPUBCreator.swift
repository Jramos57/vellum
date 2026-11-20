import Foundation

/// Creates EPUB archives from structured input models.
public struct EPUBCreator: Sendable {
    /// Creates an EPUB creator.
    public init() {}

    /// Creates an EPUB archive from a request payload.
    ///
    /// - Parameters:
    ///   - request: Structured content and metadata input.
    ///   - outputURL: Destination archive URL.
    /// - Throws: ``VellumError`` when validation or I/O fails.
    public func createEPUB(_ request: CreateRequest, outputURL: URL) throws {
        try createEPUBSync(request, outputURL: outputURL)
    }

    /// Creates an EPUB archive from a request payload.
    ///
    /// - Parameters:
    ///   - request: Structured content and metadata input.
    ///   - outputURL: Destination archive URL.
    /// - Throws: ``VellumError`` when validation or I/O fails.
    public func createEPUB(_ request: CreateRequest, outputURL: URL) async throws {
        try createEPUBSync(request, outputURL: outputURL)
    }

    private func createEPUBSync(_ request: CreateRequest, outputURL: URL) throws {
        try validateRequest(request)
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        try writeMimetype(at: temp)
        try writeContainerXML(at: temp)
        try writeContentFiles(request: request, at: temp)
        try ZipTool.makeArchive(from: temp, output: outputURL)
        try ZipTool.validateMimetypeConstraints(archiveURL: outputURL)
    }

    private func validateRequest(_ request: CreateRequest) throws {
        var diagnostics: [VellumDiagnostic] = []
        if request.chapters.isEmpty {
            diagnostics.append(
                .init(
                    code: "CRT001",
                    specRule: "EPUB Package Spine",
                    message: "Book must include at least one chapter.",
                    hint: "Provide at least one chapter in CreateRequest.chapters."
                )
            )
        }
        // Names are compared the way Apple's file systems compare them, so
        // `Chapter1.xhtml` can't silently overwrite `chapter1.xhtml`.
        let allFiles = request.chapters.map(\.fileName) + request.assets.map(\.relativePath)
        let duplicated = Dictionary(grouping: allFiles, by: Self.fileKey).filter { $1.count > 1 }
        if !duplicated.isEmpty {
            diagnostics.append(
                .init(
                    code: "CRT002",
                    specRule: "EPUB Manifest Unique HREF",
                    message: "Duplicate file names found: \(duplicated.values.flatMap { $0 }.sorted().joined(separator: ", ")).",
                    hint: "Each chapter and asset must have a unique file name."
                )
            )
        }
        let unsafe = request.chapters.filter { Self.isUnsafePath($0.fileName) }
        if !unsafe.isEmpty {
            diagnostics.append(
                .init(
                    code: "CRT003",
                    specRule: "EPUB Resource Path Safety",
                    message: "One or more chapter file names are unsafe.",
                    hint: "Use package-relative file names without absolute paths or traversal."
                )
            )
        }
        for chapter in request.chapters {
            if let xhtml = chapter.xhtml, let problem = Self.wellFormednessProblem(xhtml) {
                diagnostics.append(
                    .init(
                        code: "CRT004",
                        specRule: "EPUB XHTML Content Document Well-formedness",
                        filePath: chapter.fileName,
                        message: "XHTML chapter is not well-formed XML: \(problem).",
                        hint: "Supply a complete, well-formed XHTML document; it is written to the package verbatim."
                    )
                )
            }
        }
        for asset in request.assets where Self.isUnsafePath(asset.relativePath) {
            diagnostics.append(
                .init(
                    code: "CRT005",
                    specRule: "EPUB Resource Path Safety",
                    filePath: asset.relativePath,
                    message: "Asset path is unsafe.",
                    hint: "Use a package-relative path without absolute paths or traversal."
                )
            )
        }
        let ids = request.chapters.map(\.id) + request.assets.map(\.id) + generatedManifestIDs(request)
        let duplicateIDs = Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted()
        if !duplicateIDs.isEmpty {
            diagnostics.append(
                .init(
                    code: "CRT006",
                    specRule: "EPUB Manifest Unique IDs",
                    message: "Manifest ids are used more than once: \(duplicateIDs.joined(separator: ", ")).",
                    hint: "Give every chapter and asset a unique id; nav, ncx and css are reserved for generated files."
                )
            )
        }
        let generated = Set(generatedFiles(request).map(Self.fileKey))
        let reserved = allFiles.filter { generated.contains(Self.fileKey($0)) || Self.fileKey($0).hasPrefix("../") }
        if !reserved.isEmpty {
            diagnostics.append(
                .init(
                    code: "CRT007",
                    specRule: "EPUB Package Generated Files",
                    message: "File name(s) collide with files the creator generates: \(reserved.joined(separator: ", ")).",
                    hint: "Rename chapters or assets that would be written as content.opf, nav.xhtml, toc.ncx or styles/main.css."
                )
            )
        }
        let chapterKeys = Set(request.chapters.map { Self.fileKey($0.fileName) })
        let badLandmarks = (request.landmarks ?? []).filter { landmark in
            !chapterKeys.contains(Self.fileKey(Self.filePart(of: landmark.href))) || landmark.type.isEmpty
        }
        if !badLandmarks.isEmpty {
            diagnostics.append(
                .init(
                    code: "CRT008",
                    specRule: "EPUB Navigation Target Validity",
                    message: "Landmark(s) don't point at a chapter or lack a type: \(badLandmarks.map(\.href).joined(separator: ", ")).",
                    hint: "Point each landmark at a chapter fileName (optionally with #fragment) and give it an epub:type."
                )
            )
        }
        if !request.chapters.isEmpty {
            if !request.chapters.contains(where: \.includeInNavigation) {
                diagnostics.append(
                    .init(
                        code: "CRT009",
                        specRule: "EPUB Navigation Document toc",
                        message: "No chapter is included in navigation.",
                        hint: "The toc nav must list at least one chapter; set includeInNavigation on one or more."
                    )
                )
            }
            if !request.chapters.contains(where: \.linear) {
                diagnostics.append(
                    .init(
                        code: "CRT010",
                        specRule: "EPUB Package Spine linear",
                        message: "No chapter is in the default reading order.",
                        hint: "At least one spine item must be linear; set linear on one or more chapters."
                    )
                )
            }
        }
        if !diagnostics.isEmpty {
            throw VellumError.strictValidationFailed(diagnostics)
        }
    }

    // MARK: - Request helpers

    /// The default stylesheet is written only when a chapter is converted from
    /// Markdown (or for the feature demo); XHTML chapters bring their own CSS.
    private func usesDefaultStylesheet(_ request: CreateRequest) -> Bool {
        request.addFeatureDemoContent || request.chapters.contains { $0.xhtml == nil }
    }

    private func generatedManifestIDs(_ request: CreateRequest) -> [String] {
        var ids = ["nav"]
        if usesDefaultStylesheet(request) { ids.append("css") }
        if request.includeLegacyNCX { ids.append("ncx") }
        if request.addFeatureDemoContent {
            ids += ["cover-image", "svg-demo", "image-gif", "image-webp", "font-demo", "font-woff", "font-woff2",
                    "font-ttf", "audio-demo", "audio-opus", "video-demo", "script-demo", "media-overlay"]
        }
        return ids
    }

    private func generatedFiles(_ request: CreateRequest) -> [String] {
        var files = ["content.opf", "nav.xhtml"]
        if usesDefaultStylesheet(request) { files.append(Self.defaultStylesheetPath) }
        if request.includeLegacyNCX { files.append("toc.ncx") }
        if request.addFeatureDemoContent {
            files += ["images/cover.jpg", "images/diagram.svg", "images/anim.gif", "images/pattern.webp",
                      "fonts/demo.otf", "fonts/demo.woff", "fonts/demo.woff2", "fonts/demo.ttf",
                      "audio/sample.mp3", "audio/sample.opus", "video/sample.mp4", "scripts/app.js",
                      "overlays/chapter1.smil"]
        }
        return files
    }

    private static let defaultStylesheetPath = "styles/main.css"

    /// Creator names are literal file names, not hrefs: encode first so a
    /// literal `%` isn't decoded when the names are compared.
    private static func fileKey(_ fileName: String) -> String {
        EPUBHref.fileKey(EPUBHref.encoding(fileName: fileName))
    }

    private static func isUnsafePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("\\") { return true }
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        return components.contains("..") || path.contains(":")
    }

    private static func filePart(of href: String) -> String {
        String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The href for a landmark target: the file part is percent-encoded like
    /// every other creator href; the fragment is kept as written.
    private static func encodedHref(_ href: String) -> String {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let file = EPUBHref.encoding(fileName: String(parts[0]))
        return parts.count > 1 ? file + "#" + parts[1] : file
    }

    /// Returns why an XHTML document isn't well-formed, or `nil` when it is.
    /// Element balance is checked too, because FoundationXML on Linux accepts
    /// some truncated documents.
    static func wellFormednessProblem(_ xhtml: String) -> String? {
        let parser = XMLParser(data: EPUBDocumentText.parserData(from: xhtml))
        let balance = XMLElementBalance()
        parser.delegate = balance
        if !parser.parse() || parser.parserError != nil {
            let reason = parser.parserError.map { ($0 as NSError).localizedDescription } ?? "parse failed"
            return "line \(parser.lineNumber): \(reason)"
        }
        return balance.isBalanced ? nil : "unbalanced or missing elements"
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMimetype(at root: URL) throws {
        let path = root.appendingPathComponent("mimetype")
        try Data("application/epub+zip".utf8).write(to: path)
    }

    private func writeContainerXML(at root: URL) throws {
        let metaInf = root.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try Data(container.utf8).write(to: metaInf.appendingPathComponent("container.xml"))
    }

    private func writeContentFiles(request: CreateRequest, at root: URL) throws {
        let oebps = root.appendingPathComponent(Internal.oebps)
        let styles = oebps.appendingPathComponent("styles")
        let images = oebps.appendingPathComponent("images")
        let fonts = oebps.appendingPathComponent("fonts")
        let scripts = oebps.appendingPathComponent("scripts")
        let audio = oebps.appendingPathComponent("audio")
        let video = oebps.appendingPathComponent("video")
        let overlays = oebps.appendingPathComponent("overlays")

        for dir in [oebps, styles, images, fonts, scripts, audio, video, overlays] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if usesDefaultStylesheet(request) {
            try writeStylesheet(at: oebps.appendingPathComponent(Self.defaultStylesheetPath))
        }
        if request.addFeatureDemoContent {
            try writeFeatureAssets(at: oebps)
        }

        for (index, chapter) in request.chapters.enumerated() {
            let chapterXHTML = chapter.xhtml ?? makeChapterXHTML(
                title: chapter.title,
                markdown: chapter.markdown,
                includeFeatureDemo: request.addFeatureDemoContent && index == 0
            )
            let target = oebps.appendingPathComponent(chapter.fileName)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(chapterXHTML.utf8).write(to: target)
        }

        for asset in request.assets {
            let fileURL = oebps.appendingPathComponent(asset.relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try asset.data.write(to: fileURL)
        }

        let opf = makeOPF(request: request)
        try Data(opf.utf8).write(to: oebps.appendingPathComponent("content.opf"))
        let nav = makeNavXHTML(request: request)
        try Data(nav.utf8).write(to: oebps.appendingPathComponent("nav.xhtml"))
        if request.includeLegacyNCX {
            let ncx = makeNCX(request: request)
            try Data(ncx.utf8).write(to: oebps.appendingPathComponent("toc.ncx"))
        }
    }

    private func writeStylesheet(at url: URL) throws {
        let css = """
        html, body {
            margin: 0;
            padding: 0;
        }
        body {
            font-family: serif;
            line-height: 1.6;
            padding: 1.5rem;
        }
        h1, h2 {
            line-height: 1.2;
        }
        img, svg, video, audio {
            max-width: 100%;
            display: block;
            margin: 1rem 0;
        }
        """
        try Data(css.utf8).write(to: url)
    }

    private func writeFeatureAssets(at oebps: URL) throws {
        let coverBytes = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAoHBwgHBgoICAkLCgkLDhgQDQwMDRsUFRAWIB0iIiAdHx8kKDQsJCYxJx8fLT0tMTU3Ojo6Iys/RD84QzQ5OjcBCgoKDg0OGxAQGi0mICYtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLf/AABEIABQAFAMBIgACEQEDEQH/xAAXAAADAQAAAAAAAAAAAAAAAAACAwQF/8QAHhAAAQQCAwAAAAAAAAAAAAAAAQACAxEhMUFRYXH/xAAVAQEBAAAAAAAAAAAAAAAAAAACA//EABgRAQEBAQEAAAAAAAAAAAAAAAERAAIx/9oADAMBAAIRAxEAPwDa2XKO7eE1ENRM4mR2QltM4U9Gi0y6w1f/2Q==") ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
        try coverBytes.write(to: oebps.appendingPathComponent("images/cover.jpg"))

        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="120" viewBox="0 0 240 120">
          <rect x="1" y="1" width="238" height="118" fill="none" stroke="black"/>
          <text x="120" y="65" text-anchor="middle" font-size="16">Vellum EPUB SVG</text>
        </svg>
        """
        try Data(svg.utf8).write(to: oebps.appendingPathComponent("images/diagram.svg"))

        try Data("OTTOFAKEFONT".utf8).write(to: oebps.appendingPathComponent("fonts/demo.otf"))
        try Data("WOFFFONT".utf8).write(to: oebps.appendingPathComponent("fonts/demo.woff"))
        try Data("WOFF2FONT".utf8).write(to: oebps.appendingPathComponent("fonts/demo.woff2"))
        try Data("TTFFONT".utf8).write(to: oebps.appendingPathComponent("fonts/demo.ttf"))
        try Data([0x49, 0x44, 0x33]).write(to: oebps.appendingPathComponent("audio/sample.mp3"))
        try Data([0x4F, 0x67, 0x67, 0x53]).write(to: oebps.appendingPathComponent("audio/sample.opus"))
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: oebps.appendingPathComponent("video/sample.mp4"))
        try Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]).write(to: oebps.appendingPathComponent("images/anim.gif"))
        try Data([0x52, 0x49, 0x46, 0x46, 0x57, 0x45, 0x42, 0x50]).write(to: oebps.appendingPathComponent("images/pattern.webp"))
        try Data("console.log('epub script');".utf8).write(to: oebps.appendingPathComponent("scripts/app.js"))
        let smil = """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
          <body>
            <seq>
              <par>
                <text src="chapter1.xhtml#p1"/>
                <audio src="../audio/sample.mp3" clipBegin="0:00:00" clipEnd="0:00:02"/>
              </par>
            </seq>
          </body>
        </smil>
        """
        try Data(smil.utf8).write(to: oebps.appendingPathComponent("overlays/chapter1.smil"))
    }

    private func makeChapterXHTML(title: String, markdown: String, includeFeatureDemo: Bool) -> String {
        let body = MarkdownConverter.markdownToXHTMLBody(markdown)
        let demo = includeFeatureDemo ? """
        <p id="p1">Feature coverage section.</p>
        <img src="images/cover.jpg" alt="Cover"/>
        <img src="images/anim.gif" alt="Animated sample"/>
        <img src="images/pattern.webp" alt="WebP sample"/>
        <object type="image/svg+xml" data="images/diagram.svg"></object>
        <audio controls="controls" src="audio/sample.mp3"></audio>
        <audio controls="controls" src="audio/sample.opus"></audio>
        <video controls="controls" src="video/sample.mp4"></video>
        <script src="scripts/app.js"></script>
        """ : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
          <title>\(title.xmlEscaped())</title>
          <link rel="stylesheet" type="text/css" href="styles/main.css"/>
        </head>
        <body>
          <section epub:type="chapter">
            \(body)
            \(demo)
          </section>
        </body>
        </html>
        """
    }

    private func makeOPF(request: CreateRequest) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var manifestItems: [String] = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
        ]
        if usesDefaultStylesheet(request) {
            manifestItems.append(#"<item id="css" href="styles/main.css" media-type="text/css"/>"#)
        }

        if request.includeLegacyNCX {
            manifestItems.append(#"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#)
        }

        if request.addFeatureDemoContent {
            manifestItems.append(#"<item id="cover-image" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#)
            manifestItems.append(#"<item id="svg-demo" href="images/diagram.svg" media-type="image/svg+xml"/>"#)
            manifestItems.append(#"<item id="image-gif" href="images/anim.gif" media-type="image/gif"/>"#)
            manifestItems.append(#"<item id="image-webp" href="images/pattern.webp" media-type="image/webp"/>"#)
            manifestItems.append(#"<item id="font-demo" href="fonts/demo.otf" media-type="font/otf"/>"#)
            manifestItems.append(#"<item id="font-woff" href="fonts/demo.woff" media-type="font/woff"/>"#)
            manifestItems.append(#"<item id="font-woff2" href="fonts/demo.woff2" media-type="font/woff2"/>"#)
            manifestItems.append(#"<item id="font-ttf" href="fonts/demo.ttf" media-type="font/ttf"/>"#)
            manifestItems.append(#"<item id="audio-demo" href="audio/sample.mp3" media-type="audio/mpeg"/>"#)
            manifestItems.append(#"<item id="audio-opus" href="audio/sample.opus" media-type="audio/ogg"/>"#)
            manifestItems.append(#"<item id="video-demo" href="video/sample.mp4" media-type="video/mp4"/>"#)
            manifestItems.append(#"<item id="script-demo" href="scripts/app.js" media-type="application/javascript"/>"#)
            manifestItems.append(#"<item id="media-overlay" href="overlays/chapter1.smil" media-type="application/smil+xml"/>"#)
        }

        for chapter in request.chapters {
            let properties = chapter.properties.joined(separator: " ")
            let propertiesAttr = properties.isEmpty ? "" : #" properties="\#(properties.xmlEscaped())""#
            manifestItems.append(#"<item id="\#(chapter.id.xmlEscaped())" href="\#(EPUBHref.encoding(fileName: chapter.fileName).xmlEscaped())" media-type="application/xhtml+xml"\#(propertiesAttr)/>"#)
        }

        for asset in request.assets {
            let properties = asset.properties.joined(separator: " ")
            if properties.isEmpty {
                manifestItems.append(#"<item id="\#(asset.id.xmlEscaped())" href="\#(EPUBHref.encoding(fileName: asset.relativePath).xmlEscaped())" media-type="\#(asset.mediaType.xmlEscaped())"/>"#)
            } else {
                manifestItems.append(#"<item id="\#(asset.id.xmlEscaped())" href="\#(EPUBHref.encoding(fileName: asset.relativePath).xmlEscaped())" media-type="\#(asset.mediaType.xmlEscaped())" properties="\#(properties.xmlEscaped())"/>"#)
            }
        }

        let spineItems = request.chapters.map { chapter in
            #"<itemref idref="\#(chapter.id.xmlEscaped())"\#(chapter.linear ? "" : #" linear="no""#)/>"#
        }.joined(separator: "\n    ")
        let tocAttr = request.includeLegacyNCX ? #" toc="ncx""# : ""
        // EPUB 2 reading systems find the cover through <meta name="cover">.
        let coverID = request.assets.first { $0.properties.contains("cover-image") }?.id
            ?? (request.addFeatureDemoContent ? "cover-image" : nil)
        var extraMetadata = request.metadata.subjects.map { "<dc:subject>\($0.xmlEscaped())</dc:subject>" }
        if let source = request.metadata.source { extraMetadata.append("<dc:source>\(source.xmlEscaped())</dc:source>") }
        if let coverID { extraMetadata.append(#"<meta name="cover" content="\#(coverID.xmlEscaped())"/>"#) }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(request.metadata.identifier.xmlEscaped())</dc:identifier>
            <dc:title>\(request.metadata.title.xmlEscaped())</dc:title>
            <dc:creator>\(request.metadata.creator.xmlEscaped())</dc:creator>
            <dc:language>\(request.metadata.language.xmlEscaped())</dc:language>
            <meta property="dcterms:modified">\(formatter.string(from: request.metadata.modified))</meta>
            \(request.metadata.publisher.map { "<dc:publisher>\($0.xmlEscaped())</dc:publisher>" } ?? "")
            \(request.metadata.description.map { "<dc:description>\($0.xmlEscaped())</dc:description>" } ?? "")
            \(request.metadata.rights.map { "<dc:rights>\($0.xmlEscaped())</dc:rights>" } ?? "")
            \(extraMetadata.joined(separator: "\n    "))
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

    private func makeNavXHTML(request: CreateRequest) -> String {
        let tocItems = request.chapters.filter(\.includeInNavigation).map { #"<li><a href="\#(EPUBHref.encoding(fileName: $0.fileName).xmlEscaped())">\#($0.title.xmlEscaped())</a></li>"# }.joined(separator: "\n      ")
        let landmarks = request.landmarks ?? [
            EPUBLandmark(type: "bodymatter", title: "Start", href: request.chapters.first?.fileName ?? "chapter1.xhtml")
        ]
        let landmarkItems = landmarks.map { landmark in
            #"<li><a epub:type="\#(landmark.type.xmlEscaped())" href="\#(Self.encodedHref(landmark.href).xmlEscaped())">\#(landmark.title.xmlEscaped())</a></li>"#
        }.joined(separator: "\n      ")
        let landmarksNav = landmarks.isEmpty ? "" : """
          <nav epub:type="landmarks" id="landmarks">
            <h2>Landmarks</h2>
            <ol>
              \(landmarkItems)
            </ol>
          </nav>
        """
        let pageList = request.chapters.enumerated().map { idx, chapter in
            #"<li><a href="\#(EPUBHref.encoding(fileName: chapter.fileName).xmlEscaped())">Page \#(idx + 1)</a></li>"#
        }.joined(separator: "\n      ")
        let pageListNav = !request.includeGeneratedPageList ? "" : """
          <nav epub:type="page-list" id="page-list">
            <h2>Pages</h2>
            <ol>
              \(pageList)
            </ol>
          </nav>
        """
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
              \(tocItems)
            </ol>
          </nav>
        \(landmarksNav)
        \(pageListNav)
        </body>
        </html>
        """
    }

    private func makeNCX(request: CreateRequest) -> String {
        let navPoints = request.chapters.filter(\.includeInNavigation).enumerated().map { idx, chapter in
            """
            <navPoint id="navPoint-\(idx + 1)" playOrder="\(idx + 1)">
              <navLabel><text>\(chapter.title.xmlEscaped())</text></navLabel>
              <content src="\(EPUBHref.encoding(fileName: chapter.fileName).xmlEscaped())"/>
            </navPoint>
            """
        }.joined(separator: "\n    ")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(request.metadata.identifier.xmlEscaped())"/>
          </head>
          <docTitle><text>\(request.metadata.title.xmlEscaped())</text></docTitle>
          <navMap>
            \(navPoints)
          </navMap>
        </ncx>
        """
    }
}
