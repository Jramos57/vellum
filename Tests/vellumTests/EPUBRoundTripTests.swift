import Foundation
import Testing
@testable import vellum

@Test func sampleBookRoundTripCreateParseAndMarkdown() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()

    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 10)
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-sample-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    try creator.createEPUB(request, outputURL: outputURL)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let book = try parser.parseEPUB(at: outputURL)
    #expect(book.chapters.count == 10)
    #expect(book.metadata.title == "Vellum Lorem Ipsum Sample")
    #expect(book.metadata.publisher == "Vellum Labs")
    #expect(book.metadata.description?.contains("feature coverage") == true)
    #expect(book.metadata.rights == "Public Domain Sample")

    let markdown = book.renderStructuredMarkdown()
    #expect(markdown.contains("# Vellum Lorem Ipsum Sample"))
    #expect(markdown.contains("### Chapter 1"))
    #expect(markdown.contains("### Chapter 10"))
}

@Test func strictValidationFailsForMalformedArchive() throws {
    let parser = EPUBParser()
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-invalid-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: temp) }
    try Data("not an epub".utf8).write(to: temp)

    #expect {
        try parser.parseEPUB(at: temp)
    } throws: { error in
        guard case let VellumError.ioFailure(message) = error else { return false }
        return !message.isEmpty
    }
}

@Test func generatedOPFContainsFeatureCoverageEntries() throws {
    let creator = EPUBCreator()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 10)
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-features-\(UUID().uuidString).epub")
    let unzipDir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-features-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: unzipDir)
    }

    try creator.createEPUB(request, outputURL: outputURL)
    try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-q", outputURL.path, "-d", unzipDir.path]
    try unzip.run()
    unzip.waitUntilExit()
    #expect(unzip.terminationStatus == 0)

    let opfURL = unzipDir.appendingPathComponent("OEBPS/content.opf")
    let opf = try String(contentsOf: opfURL, encoding: .utf8)
    #expect(opf.contains("media-type=\"image/jpeg\""))
    #expect(opf.contains("media-type=\"image/svg+xml\""))
    #expect(opf.contains("media-type=\"application/javascript\""))
    #expect(opf.contains("media-type=\"audio/mpeg\""))
    #expect(opf.contains("media-type=\"audio/ogg\""))
    #expect(opf.contains("media-type=\"video/mp4\""))
    #expect(opf.contains("media-type=\"image/gif\""))
    #expect(opf.contains("media-type=\"image/webp\""))
    #expect(opf.contains("media-type=\"font/woff\""))
    #expect(opf.contains("media-type=\"font/woff2\""))
    #expect(opf.contains("media-type=\"font/ttf\""))
    #expect(opf.contains("media-type=\"font/otf\""))
    #expect(opf.contains("media-type=\"application/smil+xml\""))
}

@Test("Structured EPUB defects report their expected diagnostic", arguments: ValidationFixture.defects)
private func strictValidationReportsExpectedDiagnostic(fixture: ValidationFixture) throws {
    try withRebuiltSampleEPUB(chapterCount: fixture.chapterCount, mutate: fixture.mutate) { rebuilt in
        do {
            _ = try EPUBParser().parseEPUB(at: rebuilt)
            Issue.record("Expected strict validation failure for \(fixture.label).")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnosticsContainCode(diagnostics, fixture.expectedCode))
        }
    }
}

@Test func parserFallsBackToNCXWhenNavIsRemoved() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-ncx-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-ncx-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
    try FileManager.default.removeItem(at: navURL)

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(of: #"version="3.0""#, with: #"version="2.0""#)
    opf = opf.replacingOccurrences(
        of: #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
        with: ""
    )
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-ncx-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    let parsed = try parser.parseEPUB(at: rebuilt)
    #expect(parsed.toc.count == 2)
    #expect(parsed.chapters.count == 2)
}

@Test("Navigation accepts supported attribute spellings", arguments: NavigationFixture.variants)
private func parserAcceptsNavAttributeVariant(fixture: NavigationFixture) throws {
    try withRebuiltSampleEPUB(chapterCount: 2, mutate: fixture.mutate) { rebuilt in
        let parsed = try EPUBParser().parseEPUB(at: rebuilt)
        #expect(parsed.toc.count == 2)
        #expect(parsed.chapters.count == 2)
    }
}

@Test func parserAcceptsChaptersWithHTMLNamedEntities() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-entities-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-entities-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let chapterURL = dir.appendingPathComponent("OEBPS/chapter1.xhtml")
    let content = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Fish&nbsp;&amp;&nbsp;chips &mdash; caf&eacute;</p></body></html>
    """
    try Data(content.utf8).write(to: chapterURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-entities-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    let parsed = try parser.parseEPUB(at: rebuilt)
    let chapter = try #require(parsed.chapters.first(where: { $0.href == "chapter1.xhtml" }))
    #expect(chapter.plainText == "Fish & chips \u{2014} caf\u{00E9}")
}

@Test func validatorReportsValidForGeneratedSample() throws {
    let creator = EPUBCreator()
    let validator = EPUBValidator()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 3)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-validator-valid-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: epubURL) }

    try creator.createEPUB(request, outputURL: epubURL)
    let report = validator.validateEPUB(at: epubURL)
    #expect(report.isValid)
    #expect(report.diagnostics.isEmpty)
}

@Test func validatorReturnsDiagnosticsForInvalidArchive() throws {
    let validator = EPUBValidator()
    let badURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-validator-invalid-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: badURL) }
    try Data("bad epub".utf8).write(to: badURL)

    let report = validator.validateEPUB(at: badURL)
    #expect(!report.isValid)
    #expect(!report.diagnostics.isEmpty)
}

@Test func creatorCanBuildFromMarkdownDirectory() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-md-src-\(UUID().uuidString)")
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-md-build-\(UUID().uuidString).epub")
    defer {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: outputURL)
    }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try Data("# Intro\n\nHello".utf8).write(to: tempDir.appendingPathComponent("01_intro.md"))
    try Data("Chapter without heading".utf8).write(to: tempDir.appendingPathComponent("02-middle.md"))
    try Data("# Ending\n\nBye".utf8).write(to: tempDir.appendingPathComponent("10_end.md"))

    let metadata = EPUBMetadata(
        identifier: "urn:uuid:\(UUID().uuidString)",
        title: "Directory Book",
        creator: "Test"
    )

    try creator.createEPUB(
        metadata: metadata,
        markdownDirectory: tempDir,
        outputURL: outputURL,
        includeLegacyNCX: true,
        addFeatureDemoContent: false
    )

    let book = try parser.parseEPUB(at: outputURL)
    #expect(book.chapters.count == 3)
    #expect(book.chapters[0].title == "Intro")
    #expect(book.chapters[1].title == "02 Middle")
    #expect(book.chapters[2].title == "Ending")
}

@Test func creatorRejectsUnsafeChapterPath() throws {
    let creator = EPUBCreator()
    let metadata = EPUBMetadata(identifier: "urn:uuid:\(UUID().uuidString)", title: "Bad", creator: "Test")
    let request = CreateRequest(
        metadata: metadata,
        chapters: [
            EPUBChapterInput(id: "c1", title: "One", markdown: "# One", fileName: "../chapter1.xhtml")
        ]
    )

    do {
        try creator.createEPUB(request, outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("nope.epub"))
        Issue.record("Expected unsafe chapter path to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "CRT003"))
    }
}

@Test func parserRejectsUnsafeManifestHrefPath() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-unsafe-href-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-unsafe-href-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    // OPF in OEBPS/: two levels up leaves the package (one is its root).
    opf = opf.replacingOccurrences(of: "chapter1.xhtml", with: "../../chapter1.xhtml")
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-unsafe-href-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected parser to reject unsafe manifest href path.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR030"))
    }
}

private struct ValidationFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let chapterCount: Int
    let expectedCode: String
    let mutate: @Sendable (URL) throws -> Void

    var testDescription: String { "\(label) → \(expectedCode)" }

    static let defects: [Self] = [
        .init(label: "Spine References Missing Manifest Item", chapterCount: 2, expectedCode: "PAR018") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(
                of: #"<item id="chapter-1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>"#,
                with: ""
            )
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "TOC target is not in manifest", chapterCount: 2, expectedCode: "PAR024") { dir in
            let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
            var nav = try String(contentsOf: navURL, encoding: .utf8)
            nav = nav.replacingOccurrences(of: "chapter1.xhtml", with: "does-not-exist.xhtml")
            try Data(nav.utf8).write(to: navURL)
        },
        .init(label: "Manifest File Missing", chapterCount: 2, expectedCode: "PAR025") { dir in
            try FileManager.default.removeItem(at: dir.appendingPathComponent("OEBPS/chapter2.xhtml"))
        },
        .init(label: "Spine References Non XHTML", chapterCount: 2, expectedCode: "PAR023") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(of: #"<itemref idref="chapter-2"/>"#, with: #"<itemref idref="audio-demo"/>"#)
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "Nav lacks TOC section", chapterCount: 2, expectedCode: "PAR027") { dir in
            let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
            var nav = try String(contentsOf: navURL, encoding: .utf8)
            nav = nav.replacingOccurrences(of: "epub:type=\"toc\"", with: "epub:type=\"landmarks\"")
            try Data(nav.utf8).write(to: navURL)
        },
        .init(label: "Chapter XML is malformed", chapterCount: 2, expectedCode: "PAR029") { dir in
            let chapterURL = dir.appendingPathComponent("OEBPS/chapter1.xhtml")
            let bad = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><body><p>broken
            """
            try Data(bad.utf8).write(to: chapterURL)
        },
        .init(label: "Invalid Package Version", chapterCount: 1, expectedCode: "PAR032") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(of: #"version="3.0""#, with: #"version="1.0""#)
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "EPUB 2 missing NCX manifest item", chapterCount: 1, expectedCode: "PAR042") { dir in
            try FileManager.default.removeItem(at: dir.appendingPathComponent("OEBPS/toc.ncx"))
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(of: #"version="3.0""#, with: #"version="2.0""#)
            opf = opf.replacingOccurrences(
                of: #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
                with: ""
            )
            opf = opf.replacingOccurrences(of: #" toc="ncx""#, with: "")
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "EPUB 2 spine TOC reference is invalid", chapterCount: 1, expectedCode: "PAR043") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(of: #"version="3.0""#, with: #"version="2.0""#)
            opf = opf.replacingOccurrences(of: #" toc="ncx""#, with: #" toc="missing-ncx""#)
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "Manifest Media Type Is Malformed", chapterCount: 1, expectedCode: "PAR044") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(
                of: #"media-type="application/xhtml+xml""#,
                with: #"media-type="applicationxhtml+xml""#,
                options: [],
                range: opf.range(of: #"media-type="application/xhtml+xml""#)
            )
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "Broken Unique Identifier Reference", chapterCount: 1, expectedCode: "PAR033") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(of: #"unique-identifier="bookid""#, with: #"unique-identifier="missing-id-ref""#)
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "Broken Media Overlay Reference", chapterCount: 1, expectedCode: "PAR035") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(
                of: #"<item id="chapter-1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>"#,
                with: #"<item id="chapter-1" href="chapter1.xhtml" media-type="application/xhtml+xml" media-overlay="missing-overlay"/>"#
            )
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "Multiple Cover Image Properties Exist", chapterCount: 1, expectedCode: "PAR034") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(
                of: #"<item id="svg-demo" href="images/diagram.svg" media-type="image/svg+xml"/>"#,
                with: #"<item id="svg-demo" href="images/diagram.svg" media-type="image/svg+xml" properties="cover-image"/>"#
            )
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "Invalid Container Rootfile Media Type", chapterCount: 1, expectedCode: "PAR037") { dir in
            let containerURL = dir.appendingPathComponent("META-INF/container.xml")
            var container = try String(contentsOf: containerURL, encoding: .utf8)
            container = container.replacingOccurrences(of: "application/oebps-package+xml", with: "application/xml")
            try Data(container.utf8).write(to: containerURL)
        },
        .init(label: "EPUB 3 missing modified timestamp", chapterCount: 1, expectedCode: "PAR038") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(
                of: #"<meta property="dcterms:modified">"#,
                with: #"<meta property="unused:modified">"#
            )
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "EPUB 3 has no nav document", chapterCount: 2, expectedCode: "PAR039") { dir in
            try FileManager.default.removeItem(at: dir.appendingPathComponent("OEBPS/nav.xhtml"))
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(
                of: #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
                with: ""
            )
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "Language Metadata Missing", chapterCount: 1, expectedCode: "PAR040") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(of: "<dc:language>en</dc:language>", with: "")
            try Data(opf.utf8).write(to: opfURL)
        },
        .init(label: "Package Unique Identifier Missing", chapterCount: 1, expectedCode: "PAR041") { dir in
            let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
            var opf = try String(contentsOf: opfURL, encoding: .utf8)
            opf = opf.replacingOccurrences(of: #" unique-identifier="bookid""#, with: "")
            try Data(opf.utf8).write(to: opfURL)
        }
    ]
}

private struct NavigationFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let mutate: @Sendable (URL) throws -> Void

    var testDescription: String { label }

    static let variants: [Self] = [
        .init(label: "tokenized EPUB type") { dir in
            let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
            var nav = try String(contentsOf: navURL, encoding: .utf8)
            nav = nav.replacingOccurrences(of: #"epub:type="toc""#, with: #"epub:type="toc lot""#)
            try Data(nav.utf8).write(to: navURL)
        },
        .init(label: "single quoted attributes") { dir in
            let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
            var nav = try String(contentsOf: navURL, encoding: .utf8)
            nav = nav.replacingOccurrences(of: #"epub:type="toc""#, with: "epub:type='toc'")
            nav = nav.replacingOccurrences(of: #"href="chapter1.xhtml""#, with: "href='chapter1.xhtml'")
            nav = nav.replacingOccurrences(of: #"href="chapter2.xhtml""#, with: "href='chapter2.xhtml'")
            try Data(nav.utf8).write(to: navURL)
        }
    ]
}

private func withRebuiltSampleEPUB(
    chapterCount: Int,
    mutate: (URL) throws -> Void,
    check: (URL) throws -> Void
) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-fixture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let epubURL = dir.appendingPathComponent("original.epub")
    let rebuilt = dir.appendingPathComponent("rebuilt.epub")

    try EPUBCreator().createEPUB(SampleBookFactory.makeLoremIpsumBook(chapterCount: chapterCount), outputURL: epubURL)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])
    try mutate(dir)
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)
    try check(rebuilt)
}

private func diagnosticsContainCode(_ diagnostics: [VellumDiagnostic], _ code: String) -> Bool {
    diagnostics.contains(where: { $0.code == code })
}

private func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd {
        process.currentDirectoryURL = cwd
    }
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        Issue.record("Command failed: \(executable) \(arguments.joined(separator: " "))")
        throw NSError(domain: "vellumTests", code: Int(process.terminationStatus))
    }
}
