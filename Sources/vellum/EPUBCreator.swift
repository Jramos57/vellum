import Foundation

public struct EPUBCreator: Sendable {
    public init() {}

    public func createEPUB(_ request: CreateRequest, outputURL: URL) throws {
        try createEPUBSync(request, outputURL: outputURL)
    }

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
        let duplicated = Dictionary(grouping: request.chapters, by: \.fileName).filter { $1.count > 1 }
        if !duplicated.isEmpty {
            diagnostics.append(
                .init(
                    code: "CRT002",
                    specRule: "EPUB Manifest Unique HREF",
                    message: "Duplicate chapter filenames found.",
                    hint: "Each chapter must have a unique fileName."
                )
            )
        }
        if !diagnostics.isEmpty {
            throw VellumError.strictValidationFailed(diagnostics)
        }
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

        for dir in [oebps, styles, images, fonts, scripts, audio, video] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try writeStylesheet(at: styles.appendingPathComponent("main.css"))
        if request.addFeatureDemoContent {
            try writeFeatureAssets(at: oebps)
        }

        for chapter in request.chapters {
            let chapterXHTML = makeChapterXHTML(title: chapter.title, markdown: chapter.markdown)
            let target = oebps.appendingPathComponent(chapter.fileName)
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
        try Data([0x49, 0x44, 0x33]).write(to: oebps.appendingPathComponent("audio/sample.mp3"))
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: oebps.appendingPathComponent("video/sample.mp4"))
        try Data("console.log('epub script');".utf8).write(to: oebps.appendingPathComponent("scripts/app.js"))
    }

    private func makeChapterXHTML(title: String, markdown: String) -> String {
        let body = MarkdownConverter.markdownToXHTMLBody(markdown)
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
          </section>
        </body>
        </html>
        """
    }

    private func makeOPF(request: CreateRequest) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var manifestItems: [String] = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            #"<item id="css" href="styles/main.css" media-type="text/css"/>"#
        ]

        if request.includeLegacyNCX {
            manifestItems.append(#"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#)
        }

        if request.addFeatureDemoContent {
            manifestItems.append(#"<item id="cover-image" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#)
            manifestItems.append(#"<item id="svg-demo" href="images/diagram.svg" media-type="image/svg+xml"/>"#)
            manifestItems.append(#"<item id="font-demo" href="fonts/demo.otf" media-type="font/otf"/>"#)
            manifestItems.append(#"<item id="audio-demo" href="audio/sample.mp3" media-type="audio/mpeg"/>"#)
            manifestItems.append(#"<item id="video-demo" href="video/sample.mp4" media-type="video/mp4"/>"#)
            manifestItems.append(#"<item id="script-demo" href="scripts/app.js" media-type="application/javascript"/>"#)
        }

        for chapter in request.chapters {
            manifestItems.append(#"<item id="\#(chapter.id.xmlEscaped())" href="\#(chapter.fileName.xmlEscaped())" media-type="application/xhtml+xml"/>"#)
        }

        for asset in request.assets {
            let properties = asset.properties.joined(separator: " ")
            if properties.isEmpty {
                manifestItems.append(#"<item id="\#(asset.id.xmlEscaped())" href="\#(asset.relativePath.xmlEscaped())" media-type="\#(asset.mediaType.xmlEscaped())"/>"#)
            } else {
                manifestItems.append(#"<item id="\#(asset.id.xmlEscaped())" href="\#(asset.relativePath.xmlEscaped())" media-type="\#(asset.mediaType.xmlEscaped())" properties="\#(properties.xmlEscaped())"/>"#)
            }
        }

        let spineItems = request.chapters.map { #"<itemref idref="\#($0.id.xmlEscaped())"/>"# }.joined(separator: "\n    ")
        let tocAttr = request.includeLegacyNCX ? #" toc="ncx""# : ""

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
        let tocItems = request.chapters.map { #"<li><a href="\#($0.fileName.xmlEscaped())">\#($0.title.xmlEscaped())</a></li>"# }.joined(separator: "\n      ")
        let pageList = request.chapters.enumerated().map { idx, chapter in
            #"<li><a href="\#(chapter.fileName.xmlEscaped())">Page \#(idx + 1)</a></li>"#
        }.joined(separator: "\n      ")
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
          <nav epub:type="landmarks" id="landmarks">
            <h2>Landmarks</h2>
            <ol>
              <li><a epub:type="bodymatter" href="\(request.chapters.first?.fileName.xmlEscaped() ?? "chapter1.xhtml")">Start</a></li>
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

    private func makeNCX(request: CreateRequest) -> String {
        let navPoints = request.chapters.enumerated().map { idx, chapter in
            """
            <navPoint id="navPoint-\(idx + 1)" playOrder="\(idx + 1)">
              <navLabel><text>\(chapter.title.xmlEscaped())</text></navLabel>
              <content src="\(chapter.fileName.xmlEscaped())"/>
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
