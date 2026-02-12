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
    #expect(opf.contains("media-type=\"video/mp4\""))
    #expect(opf.contains("media-type=\"font/otf\""))
}
