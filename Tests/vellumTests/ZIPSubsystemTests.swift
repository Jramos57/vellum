import Foundation
import Testing
@testable import vellum

@Test func ZIPSubsystemExtractsStandardEPUBArchive() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-standard-\(UUID().uuidString)")
    let source = workspace.appendingPathComponent("source")
    let archiveURL = workspace.appendingPathComponent("standard.epub")
    let extractURL = workspace.appendingPathComponent("extract")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)

    try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
    try Data(containerXML.utf8).write(to: source.appendingPathComponent("META-INF/container.xml"))
    try Data(opfXML.utf8).write(to: source.appendingPathComponent("OEBPS/content.opf"))

    try run("/usr/bin/zip", ["-X0q", archiveURL.path, "mimetype"], cwd: source)
    try run("/usr/bin/zip", ["-Xr9q", archiveURL.path, "META-INF", "OEBPS"], cwd: source)

    try ZipTool.extractArchive(archiveURL, to: extractURL)

    #expect(FileManager.default.fileExists(atPath: extractURL.appendingPathComponent("mimetype").path))
    #expect(FileManager.default.fileExists(atPath: extractURL.appendingPathComponent("META-INF/container.xml").path))
    #expect(FileManager.default.fileExists(atPath: extractURL.appendingPathComponent("OEBPS/content.opf").path))

    let mimetype = try String(contentsOf: extractURL.appendingPathComponent("mimetype"), encoding: .utf8)
    #expect(mimetype == "application/epub+zip")
}

@Test func ZIPSubsystemCreatesStoredAndDeflatedEntries() throws {
    let creator = EPUBCreator()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)
    let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-methods-\(UUID().uuidString).epub")

    defer {
        try? FileManager.default.removeItem(at: archiveURL)
    }

    try creator.createEPUB(request, outputURL: archiveURL)

    let reader = try ZipArchiveReader(url: archiveURL)
    #expect(reader.entries.first?.path == "mimetype")
    #expect(reader.entries.first?.compressionMethod == .store)
    #expect(reader.entries.contains(where: { $0.path != "mimetype" && $0.compressionMethod == .deflate }))
}

@Test func ZIPSubsystemRejectsPathTraversalEntry() throws {
    let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-traversal-\(UUID().uuidString).epub")
    let extractURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-traversal-out-\(UUID().uuidString)")

    defer {
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: extractURL)
    }

    try ZipArchiveWriter.write(
        entries: [
            .init(path: "../evil.txt", data: Data("owned".utf8), compressionMethod: .store)
        ],
        to: archiveURL
    )

    do {
        try ZipTool.extractArchive(archiveURL, to: extractURL)
        Issue.record("Expected ZIP path traversal archive to be rejected.")
    } catch let VellumError.ioFailure(message) {
        #expect(message.contains("unsafe") || message.contains("escapes extraction root"))
    }
}

@Test func ZIPSubsystemRejectsCRCMismatch() throws {
    let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-crc-\(UUID().uuidString).epub")
    let extractURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-crc-out-\(UUID().uuidString)")

    defer {
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: extractURL)
    }

    try ZipArchiveWriter.write(
        entries: [
            .init(
                path: "payload.txt",
                data: Data("hello".utf8),
                compressionMethod: .store,
                crc32Override: 0
            )
        ],
        to: archiveURL
    )

    do {
        try ZipTool.extractArchive(archiveURL, to: extractURL)
        Issue.record("Expected CRC mismatch to fail extraction.")
    } catch let VellumError.ioFailure(message) {
        #expect(message.contains("CRC32"))
    }
}

@Test func ZIPSubsystemCRC32MatchesKnownVectors() {
    #expect(ZipCRC32.checksum(Data()) == 0x0000_0000)
    #expect(ZipCRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    #expect(ZipCRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
}

@Test func ZIPSubsystemRoundTripsDeflateStreams() throws {
    var samples: [Data] = [
        Data(),
        Data("a".utf8),
        Data(String(repeating: "repeated phrase ", count: 5_000).utf8),
        Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    ]
    samples.append(Data(repeating: 0xAB, count: 150_000))

    for sample in samples {
        let compressed = try ZipDeflate.compress(sample)
        let restored = try ZipDeflate.decompress(compressed, expectedSize: sample.count)
        #expect(restored == sample)
    }
}

@Test func ZIPSubsystemInflatesSystemCompressedEntries() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-inflate-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("system.zip")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let payload = Data(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 512).utf8)
    try payload.write(to: workspace.appendingPathComponent("payload.txt"))
    try run("/usr/bin/zip", ["-9q", archiveURL.path, "payload.txt"], cwd: workspace)

    let reader = try ZipArchiveReader(url: archiveURL)
    let entry = try #require(reader.entries.first(where: { $0.path == "payload.txt" }))
    #expect(entry.compressionMethod == .deflate)
    #expect(try reader.data(for: entry) == payload)
}

@Test func ZIPSubsystemWritesArchivesSystemUnzipExtracts() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-deflate-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("in-house.zip")
    let extractURL = workspace.appendingPathComponent("extract")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })

    try ZipArchiveWriter.write(
        entries: [
            .init(path: "payload.bin", data: payload, compressionMethod: .deflate)
        ],
        to: archiveURL
    )

    try run("/usr/bin/unzip", ["-q", archiveURL.path, "-d", extractURL.path])
    let extracted = try Data(contentsOf: extractURL.appendingPathComponent("payload.bin"))
    #expect(extracted == payload)
}

@Test func ZIPSubsystemRejectsMalformedDeflateStreams() throws {
    let malformedStreams: [Data] = [
        Data(),
        Data([0xFF]),
        Data([0x01, 0x01, 0x00, 0xFE, 0xFF])
    ]

    for stream in malformedStreams {
        do {
            _ = try ZipDeflate.decompress(stream)
            Issue.record("Expected malformed DEFLATE stream to fail: \(stream as NSData)")
        } catch is ZipArchiveError {
            continue
        }
    }
}

private let containerXML = """
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

private let opfXML = """
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:00000000-0000-0000-0000-000000000000</dc:identifier>
    <dc:title>ZIP Test</dc:title>
    <dc:creator>Vellum</dc:creator>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-02-21T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine>
  </spine>
</package>
"""

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
