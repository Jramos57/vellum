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

    do {
        _ = try parser.parseEPUB(at: temp)
        Issue.record("Expected strict validation failure for malformed archive.")
    } catch let error as VellumError {
        switch error {
        case .strictValidationFailed, .ioFailure:
            #expect(Bool(true))
        default:
            Issue.record("Unexpected error type: \(error)")
        }
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

@Test func strictValidationFailsWhenSpineReferencesMissingManifestItem() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-broken-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-broken-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(
        of: #"<item id="chapter-1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>"#,
        with: ""
    )
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-broken-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected strict validation failure for broken spine-manifest reference.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diags.contains(where: { $0.code == "PAR018" || $0.code == "PAR005" }))
    }
}

@Test func parserRejectsEncryptionXMLAsUnsupported() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-encrypted-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-encrypted-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let encryptionURL = dir.appendingPathComponent("META-INF/encryption.xml")
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"/>
    """
    try Data(xml.utf8).write(to: encryptionURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-encrypted-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected unsupportedFeature error when encryption.xml is present.")
    } catch let VellumError.unsupportedFeature(_, diagnostics) {
        #expect(diagnosticsContainCode(diagnostics, "PAR020"))
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

@Test func strictValidationFailsWhenTOCTargetIsNotInManifest() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-badtoc-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-badtoc-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
    var nav = try String(contentsOf: navURL, encoding: .utf8)
    nav = nav.replacingOccurrences(of: "chapter1.xhtml", with: "does-not-exist.xhtml")
    try Data(nav.utf8).write(to: navURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-badtoc-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected strict validation failure for invalid TOC href.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR024"))
    }
}

@Test func strictValidationFailsWhenManifestFileMissing() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-missingfile-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-missingfile-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    try FileManager.default.removeItem(at: dir.appendingPathComponent("OEBPS/chapter2.xhtml"))

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-missingfile-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected strict validation failure for missing manifest file.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR025"))
    }
}

@Test func strictValidationFailsWhenSpineReferencesNonXHTML() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nonxhtml-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nonxhtml-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(of: #"<itemref idref="chapter-2"/>"#, with: #"<itemref idref="audio-demo"/>"#)
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nonxhtml-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected strict validation failure for non-XHTML spine item.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR023"))
    }
}

@Test func strictValidationFailsWhenNavLacksTOCSection() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-notoc-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-notoc-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
    var nav = try String(contentsOf: navURL, encoding: .utf8)
    nav = nav.replacingOccurrences(of: "epub:type=\"toc\"", with: "epub:type=\"landmarks\"")
    try Data(nav.utf8).write(to: navURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-notoc-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected strict validation failure for missing toc nav section.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR027"))
    }
}

@Test func parserAcceptsNavTOCWithTokenizedEPUBType() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-tokenized-toc-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-tokenized-toc-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
    var nav = try String(contentsOf: navURL, encoding: .utf8)
    nav = nav.replacingOccurrences(of: #"epub:type="toc""#, with: #"epub:type="toc lot""#)
    try Data(nav.utf8).write(to: navURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-tokenized-toc-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    let parsed = try parser.parseEPUB(at: rebuilt)
    #expect(parsed.toc.count == 2)
    #expect(parsed.chapters.count == 2)
}

@Test func parserAcceptsNavTOCSingleQuotedAttributes() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-singlequote-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-singlequote-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let navURL = dir.appendingPathComponent("OEBPS/nav.xhtml")
    var nav = try String(contentsOf: navURL, encoding: .utf8)
    nav = nav.replacingOccurrences(of: #"epub:type="toc""#, with: "epub:type='toc'")
    nav = nav.replacingOccurrences(of: #"href="chapter1.xhtml""#, with: "href='chapter1.xhtml'")
    nav = nav.replacingOccurrences(of: #"href="chapter2.xhtml""#, with: "href='chapter2.xhtml'")
    try Data(nav.utf8).write(to: navURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-singlequote-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    let parsed = try parser.parseEPUB(at: rebuilt)
    #expect(parsed.toc.count == 2)
    #expect(parsed.chapters.count == 2)
}

@Test func strictValidationFailsWhenChapterXMLMalformed() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-badxml-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-badxml-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let chapterURL = dir.appendingPathComponent("OEBPS/chapter1.xhtml")
    let bad = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><body><p>broken
    """
    try Data(bad.utf8).write(to: chapterURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-badxml-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected strict validation failure for malformed chapter XML.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR029"))
    }
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

@Test func sampleFactoryDefaultsToTenChapters() {
    let request = SampleBookFactory.makeLoremIpsumBook()
    #expect(request.chapters.count == 10)
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
    opf = opf.replacingOccurrences(of: "chapter1.xhtml", with: "../chapter1.xhtml")
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

@Test func strictValidationFailsOnInvalidPackageVersion() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-version-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-version-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(of: #"version="3.0""#, with: #"version="1.0""#)
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-version-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected invalid package version to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR032"))
    }
}

@Test func strictValidationFailsWhenEPUB2MissingNCXManifestItem() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-epub2-no-ncx-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-epub2-no-ncx-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

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

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-epub2-no-ncx-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected EPUB 2 package missing NCX to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR042"))
    }
}

@Test func strictValidationFailsWhenEPUB2SpineTOCReferenceIsInvalid() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-epub2-bad-spine-toc-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-epub2-bad-spine-toc-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(of: #"version="3.0""#, with: #"version="2.0""#)
    opf = opf.replacingOccurrences(of: #" toc="ncx""#, with: #" toc="missing-ncx""#)
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-epub2-bad-spine-toc-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected EPUB 2 package with invalid spine toc reference to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR043"))
    }
}

@Test func strictValidationFailsWhenManifestMediaTypeIsMalformed() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-media-type-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-media-type-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(
        of: #"media-type="application/xhtml+xml""#,
        with: #"media-type="applicationxhtml+xml""#,
        options: [],
        range: opf.range(of: #"media-type="application/xhtml+xml""#)
    )
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-media-type-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected malformed manifest media-type to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR044"))
    }
}

@Test func strictValidationFailsOnBrokenUniqueIdentifierReference() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-uid-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-uid-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(of: #"unique-identifier="bookid""#, with: #"unique-identifier="missing-id-ref""#)
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-uid-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected broken unique-identifier reference to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR033"))
    }
}

@Test func strictValidationFailsOnBrokenMediaOverlayReference() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-overlay-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-overlay-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(
        of: #"<item id="chapter-1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>"#,
        with: #"<item id="chapter-1" href="chapter1.xhtml" media-type="application/xhtml+xml" media-overlay="missing-overlay"/>"#
    )
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-overlay-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected broken media-overlay reference to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR035"))
    }
}

@Test func strictValidationFailsWhenMultipleCoverImagePropertiesExist() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-cover-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-cover-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(
        of: #"<item id="svg-demo" href="images/diagram.svg" media-type="image/svg+xml"/>"#,
        with: #"<item id="svg-demo" href="images/diagram.svg" media-type="image/svg+xml" properties="cover-image"/>"#
    )
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-cover-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected duplicate cover-image properties to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR034"))
    }
}

@Test func strictValidationFailsOnInvalidContainerRootfileMediaType() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-container-type-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-container-type-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let containerURL = dir.appendingPathComponent("META-INF/container.xml")
    var container = try String(contentsOf: containerURL, encoding: .utf8)
    container = container.replacingOccurrences(of: "application/oebps-package+xml", with: "application/xml")
    try Data(container.utf8).write(to: containerURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-bad-container-type-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected invalid rootfile media-type to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR037"))
    }
}

@Test func strictValidationFailsWhenEPUB3MissingModifiedTimestamp() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-modified-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-modified-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(
        of: #"<meta property="dcterms:modified">"#,
        with: #"<meta property="unused:modified">"#
    )
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-modified-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected missing dcterms:modified to fail for EPUB 3.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR038"))
    }
}

@Test func strictValidationFailsWhenEPUB3HasNoNavDocument() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-nav-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-nav-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    try FileManager.default.removeItem(at: dir.appendingPathComponent("OEBPS/nav.xhtml"))
    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(
        of: #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
        with: ""
    )
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-nav-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected EPUB 3 with no nav document to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR039"))
    }
}

@Test func strictValidationFailsWhenLanguageMetadataMissing() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-language-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-language-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(of: "<dc:language>en</dc:language>", with: "")
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-language-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected missing dc:language to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR040"))
    }
}

@Test func strictValidationFailsWhenPackageUniqueIdentifierMissing() throws {
    let creator = EPUBCreator()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)

    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-uid-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-uid-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(of: #" unique-identifier="bookid""#, with: "")
    try Data(opf.utf8).write(to: opfURL)

    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-no-uid-rebuilt-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: rebuilt) }
    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    do {
        _ = try parser.parseEPUB(at: rebuilt)
        Issue.record("Expected missing package unique-identifier to fail.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diagnosticsContainCode(diags, "PAR041"))
    }
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
