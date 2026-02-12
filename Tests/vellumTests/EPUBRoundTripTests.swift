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
