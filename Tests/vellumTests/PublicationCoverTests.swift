import Foundation
import Testing
@testable import vellum

@Test func publicationResolvesEPUB3CoverImage() throws {
    let creator = EPUBCreator()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-cover3-\(UUID().uuidString).epub")

    defer {
        try? FileManager.default.removeItem(at: epubURL)
    }

    try creator.createEPUB(request, outputURL: epubURL)

    let publication = try EPUBPublicationService().open(url: epubURL)
    let cover = try #require(publication.coverResource)
    #expect(cover.href == "images/cover.jpg")
    #expect(cover.mediaType == "image/jpeg")
    #expect(cover.data?.isEmpty == false)
}

@Test func publicationResolvesLegacyEPUB2CoverMeta() throws {
    let publication = try makeEPUB2Publication { opf in
        var updated = opf.replacingOccurrences(of: #" properties="cover-image""#, with: "")
        updated = updated.replacingOccurrences(
            of: "</metadata>",
            with: "<meta name=\"cover\" content=\"cover-image\"/></metadata>"
        )
        return updated
    }

    let cover = try #require(publication.coverResource)
    #expect(cover.href == "images/cover.jpg")
}

@Test func publicationResolvesLegacyGuideCoverReference() throws {
    let publication = try makeEPUB2Publication { opf in
        var updated = opf.replacingOccurrences(of: #" properties="cover-image""#, with: "")
        updated = updated.replacingOccurrences(
            of: "</package>",
            with: "<guide><reference type=\"cover\" href=\"images/cover.jpg\"/></guide></package>"
        )
        return updated
    }

    let cover = try #require(publication.coverResource)
    #expect(cover.href == "images/cover.jpg")
}

@Test func publicationHasNoCoverWhenNoneDeclared() throws {
    let creator = EPUBCreator()
    let request = SampleBookFactory.makeReaderSafeLoremIpsumBook(chapterCount: 1)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-cover-none-\(UUID().uuidString).epub")

    defer {
        try? FileManager.default.removeItem(at: epubURL)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    let publication = try EPUBPublicationService().open(url: epubURL)
    #expect(publication.coverResource == nil)
}

private func makeEPUB2Publication(opfTransform: (String) -> String) throws -> Publication {
    let creator = EPUBCreator()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-cover2-\(UUID().uuidString).epub")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-cover2-dir-\(UUID().uuidString)")
    let rebuilt = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-cover2-rebuilt-\(UUID().uuidString).epub")

    defer {
        try? FileManager.default.removeItem(at: epubURL)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: rebuilt)
    }

    try creator.createEPUB(request, outputURL: epubURL)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", epubURL.path, "-d", dir.path])

    let opfURL = dir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(of: #"version="3.0""#, with: #"version="2.0""#)
    opf = opfTransform(opf)
    try Data(opf.utf8).write(to: opfURL)

    try run("/usr/bin/zip", ["-X0q", rebuilt.path, "mimetype"], cwd: dir)
    try run("/usr/bin/zip", ["-Xr9q", rebuilt.path, "META-INF", "OEBPS"], cwd: dir)

    return try EPUBPublicationService().open(url: rebuilt)
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
