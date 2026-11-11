import Foundation
import Testing
#if canImport(Compression)
import Compression
#endif
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

@Test func ZIPSubsystemCRC32MatchesTableForSeededPayloads() {
    for payload in seededZIPPayloads() {
        #expect(ZipCRC32.checksum(payload) == tableCRC32(payload))
    }
}

@Test func ZIPSubsystemInflateMatchesSwiftForSeededStreams() throws {
    var blockTypes: Set<UInt8> = []
    for payload in seededZIPPayloads() {
        var streams = [try ZipDeflate.compress(payload)]
        #if canImport(Compression)
        streams.append(try systemDeflate(payload))
        #endif
        for stream in streams {
            blockTypes.insert((try #require(stream.first) >> 1) & 0x03)
            // Omitting expectedSize always selects the original Swift decoder.
            let swiftOutput = try ZipInflate.decompress(stream, maxOutputBytes: payload.count)
            let output = try ZipInflate.decompress(
                stream, expectedSize: payload.count, expectedCRC32: tableCRC32(payload),
                maxOutputBytes: payload.count
            )
            #expect(output == payload)
            #expect(output == swiftOutput)
        }
    }
    #expect(blockTypes.contains(0), "The seeded corpus must exercise stored blocks.")
    #expect(blockTypes.contains(1), "The seeded corpus must exercise fixed Huffman blocks.")
    #if canImport(Compression)
    #expect(blockTypes.contains(2), "The system encoder must supply dynamic Huffman blocks.")
    #endif
}

@Test func ZIPSubsystemInflateRejectsMalformedStreamsWithKnownSizes() throws {
    let malformedStreams: [Data] = [
        Data(),
        Data([0xFF]),
        Data([0x01, 0x01, 0x00, 0xFE, 0xFF]), // Stored block missing its payload.
        Data([0x00, 0x01, 0x00, 0xFE, 0xFF, 0x41]) // Missing final block.
    ]
    for stream in malformedStreams {
        for expectedSize in [0, 1, 16] {
            #expect(throws: ZipArchiveError.self) {
                try ZipInflate.decompress(
                    stream, expectedSize: expectedSize, expectedCRC32: tableCRC32(Data([0x41]))
                )
            }
        }
    }
}

// The coordinator permits Compression's LEN/NLEN tolerance when the output's
// declared size and CRC both match. Exercise the complete archive extraction path.
#if canImport(Compression)
@Test func ZIPSubsystemAcceptsInvalidLengthComplementWhenSizeAndCRCMatch() throws {
    let payload = Data([0x41])
    let stream = Data([0x01, 0x01, 0x00, 0xFF, 0xFF, 0x41])
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellum-zip-tolerated-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: archiveURL) }

    // Store the raw stream verbatim, then mark it as DEFLATE in both headers.
    try ZipArchiveWriter.write(
        entries: [.init(path: "payload.txt", data: stream, compressionMethod: .store,
                        crc32Override: tableCRC32(payload))],
        to: archiveURL
    )
    var archive = try Data(contentsOf: archiveURL)
    let centralOffset = try #require(archive.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
    archive[8] = 8
    archive[centralOffset + 10] = 8
    // Only the low size byte changes: this fixture has six compressed bytes and
    // one uncompressed byte. All upper bytes are already zero.
    archive[22] = 1
    archive[centralOffset + 24] = 1
    try archive.write(to: archiveURL)

    let reader = try ZipArchiveReader(url: archiveURL)
    let entry = try #require(reader.entries.first)
    #expect(try reader.data(for: entry) == payload)
}
#endif

@Test func ZIPSubsystemInflateFallsBackWhenCRCDoesNotMatch() throws {
    let payload = Data([0x41])
    let crc = tableCRC32(payload)
    let malformed = Data([0x01, 0x01, 0x00, 0xFF, 0xFF, 0x41])
    do {
        _ = try ZipInflate.decompress(malformed, expectedSize: 1, expectedCRC32: crc ^ 1)
        Issue.record("Expected CRC mismatch to fall back to Swift's stored-block validation.")
    } catch ZipArchiveError.invalidArchive(let message) {
        #expect(message == "Invalid DEFLATE stored block length.")
    }

    // A successful Swift fallback returns bytes for the archive reader's final
    // CRC check, which must retain its existing error for a valid deflated stream.
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellum-zip-deflate-crc-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: archiveURL) }
    try ZipArchiveWriter.write(
        entries: [.init(path: "payload.txt", data: payload, compressionMethod: .deflate,
                        crc32Override: crc ^ 1)],
        to: archiveURL
    )
    let reader = try ZipArchiveReader(url: archiveURL)
    let entry = try #require(reader.entries.first)
    do {
        _ = try reader.data(for: entry)
        Issue.record("Expected a deflated entry with the wrong CRC to fail extraction.")
    } catch ZipArchiveError.invalidArchive(let message) {
        #expect(message == "Entry payload.txt failed CRC32 validation.")
    }
}

@Test func ZIPSubsystemInflateKeepsSwiftValidationWithoutCRC() throws {
    let malformed = Data([0x01, 0x01, 0x00, 0xFF, 0xFF, 0x41])
    #expect(throws: ZipArchiveError.self) {
        try ZipInflate.decompress(malformed, expectedSize: 1)
    }
}

@Test func ZIPSubsystemInflateRejectsIncorrectDeclaredSizes() throws {
    let payload = Data(String(repeating: "A library of stories. ", count: 100).utf8)
    let compressed = try ZipDeflate.compress(payload)
    for expectedSize in [0, 1, payload.count - 1, payload.count + 1] {
        do {
            _ = try ZipInflate.decompress(
                compressed, expectedSize: expectedSize, expectedCRC32: tableCRC32(payload)
            )
            Issue.record("Expected incorrect declaration \(expectedSize) to fail.")
        } catch ZipArchiveError.invalidArchive(let message) {
            let expectedMessage = expectedSize < payload.count
                ? "DEFLATE stream exceeds the expected uncompressed size."
                : "DEFLATE stream produced \(payload.count) bytes, expected \(expectedSize)."
            #expect(message == expectedMessage)
        }
    }
    // The extra sentinel byte must not overflow even for an unbounded caller.
    #expect(throws: ZipArchiveError.self) {
        try ZipInflate.decompress(
            Data([0x03, 0x00]), expectedSize: Int.max, expectedCRC32: 0, maxOutputBytes: Int.max
        )
    }
}

private func seededZIPPayloads() -> [Data] {
    var generator = ZIPTestGenerator()
    let boundarySizes = [0, 1, 2, 15, 257, 4096, 32_768, 32_769, 65_535, 65_536, 131_073]
    return (0..<200).map { index in
        let count = index < boundarySizes.count ? boundarySizes[index] : Int(generator.next() % 16_385)
        let motif = (0..<127).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        return Data((0..<count).map { offset in
            switch index % 4 {
            case 0: UInt8(truncatingIfNeeded: generator.next())
            case 1: UInt8(generator.next() % 8) + 65
            case 2: motif[offset % motif.count]
            default: UInt8(generator.next() % 95) + 32
            }
        })
    }
}

private struct ZIPTestGenerator {
    private var state: UInt64 = 0x1234_5678_9ABC_DEF0

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

// Opt in with VELLUM_ZIP_BENCHMARK=1 swift test --package-path vellum -c release
// --filter ZIPSubsystemBenchmark. Setup and byte comparisons are outside the timings.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VELLUM_ZIP_BENCHMARK"] == "1"))
func ZIPSubsystemBenchmark() throws {
    let byteCount = 3_000_000
    let header = Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>".utf8)
    let footer = Data("</body></html>".utf8)
    let paragraph = "<p>The reader crossed the library, following a story through its many chapters.</p>\n"
    var payload = header
    payload.append(Data(String(repeating: paragraph,
                               count: (byteCount - header.count - footer.count) / paragraph.utf8.count).utf8))
    payload.append(Data(repeating: 0x20, count: byteCount - payload.count - footer.count))
    payload.append(footer)
    #if canImport(Compression)
    let compressed = try systemDeflate(payload)
    #else
    let compressed = try ZipDeflate.compress(payload)
    #endif
    let expectedCRC = tableCRC32(payload)
    let clock = ContinuousClock()
    // Omitting the CRC selects the unchanged Swift decoder, so the before/after
    // comparison remains reproducible in one binary. System inflate includes its
    // required CRC verification; setup and equality assertions are not timed.
    for useSystem in [false, true] {
        let declaredCRC: UInt32? = useSystem ? expectedCRC : nil
        var inflateRates: [Double] = []
        var crcRates: [Double] = []
        #expect(try ZipInflate.decompress(
            compressed, expectedSize: payload.count, expectedCRC32: declaredCRC
        ) == payload)
        #expect((useSystem ? ZipCRC32.checksum(payload) : tableCRC32(payload)) == expectedCRC)

        for _ in 0..<20 {
            let inflateStart = clock.now
            let restored = try ZipInflate.decompress(
                compressed, expectedSize: payload.count, expectedCRC32: declaredCRC
            )
            let inflateDuration = inflateStart.duration(to: clock.now)
            #expect(restored == payload)
            inflateRates.append(zipMegabytesPerSecond(byteCount: byteCount, duration: inflateDuration))

            let crcStart = clock.now
            let crc = useSystem ? ZipCRC32.checksum(payload) : tableCRC32(payload)
            let crcDuration = crcStart.duration(to: clock.now)
            #expect(crc == expectedCRC)
            crcRates.append(zipMegabytesPerSecond(byteCount: byteCount, duration: crcDuration))
        }
        let inflate = inflateRates.sorted()
        let crc = crcRates.sorted()
        print(String(format: "ZIP benchmark (%@): %d bytes, %d compressed bytes, 20 iterations; median inflate %.2f MB/s; CRC32 %.2f MB/s",
                     useSystem ? "system" : "Swift reference", payload.count, compressed.count,
                     (inflate[9] + inflate[10]) / 2, (crc[9] + crc[10]) / 2))
    }
}

private func zipMegabytesPerSecond(byteCount: Int, duration: Duration) -> Double {
    let components = duration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return Double(byteCount) / 1e6 / seconds
}

private func tableCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    data.withUnsafeBytes { rawBuffer in
        for byte in rawBuffer.bindMemory(to: UInt8.self) {
            crc = (crc >> 8) ^ zipTestCRCTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
    }
    return crc ^ 0xFFFF_FFFF
}

private let zipTestCRCTable: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 {
        value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
    }
    return value
}

#if canImport(Compression)
private func systemDeflate(_ payload: Data) throws -> Data {
    var compressed = Data(count: max(1024, payload.count * 2 + 1024))
    let capacity = compressed.count
    // The C API requires a non-null source pointer even for an empty payload.
    let input = payload.isEmpty ? Data([0]) : payload
    let count = compressed.withUnsafeMutableBytes { destination in
        input.withUnsafeBytes { source in
            compression_encode_buffer(
                destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                source.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                nil, COMPRESSION_ZLIB
            )
        }
    }
    #expect(count > 0, "Compression must produce a raw DEFLATE fixture.")
    compressed.count = count
    return compressed
}
#endif

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

@Test func ZIPSubsystemFixedHuffmanCompressesRepetitiveData() throws {
    let payload = Data(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 2_000).utf8)
    let compressed = try ZipDeflate.compress(payload)

    #expect(compressed.count < payload.count / 2)
    #expect(try ZipDeflate.decompress(compressed, expectedSize: payload.count) == payload)
}

@Test func ZIPSubsystemFallsBackToStoredBlocksForIncompressibleData() throws {
    var state: UInt64 = 0x1234_5678_9ABC_DEF0
    let payload = Data((0..<100_000).map { _ -> UInt8 in
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return UInt8(truncatingIfNeeded: value ^ (value >> 31))
    })

    let compressed = try ZipDeflate.compress(payload)
    #expect(compressed.count <= payload.count + 10)
    #expect(try ZipDeflate.decompress(compressed, expectedSize: payload.count) == payload)
}

@Test func ZIPSubsystemInflatesSystemCompressedEntries() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-inflate-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("system.zip")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let payload = Data(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6_000).utf8)
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

@Test func ZIPSubsystemRejectsOversizedDeclarationBeforeExtraction() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-oversized-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("oversized.epub")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try ZipArchiveWriter.write(
        entries: [
            .init(path: "payload.txt", data: Data("tiny".utf8), compressionMethod: .store)
        ],
        to: archiveURL
    )

    // Forge a 1 GiB central-directory declaration into a tiny on-disk archive. The
    // reader must reject this while parsing, before `data(for:)` is ever reachable,
    // so nothing proportional to the declaration is ever allocated.
    try rewriteCentralDirectoryUncompressedSize(at: archiveURL, entryIndex: 0, to: 1_073_741_824)

    do {
        _ = try ZipArchiveReader(url: archiveURL)
        Issue.record("Expected an oversized entry declaration to be rejected at initialization.")
    } catch ZipArchiveError.resourceLimitExceeded(let message) {
        #expect(message.contains("per-entry"))
    }
    do {
        try ZipTool.extractArchive(archiveURL, to: workspace.appendingPathComponent("extract"))
        Issue.record("Expected extraction to preserve the public resource-limit error.")
    } catch VellumError.resourceLimitExceeded(let message) {
        #expect(message.contains("per-entry"))
    }
    do {
        try ZipTool.validateMimetypeConstraints(archiveURL: archiveURL)
        Issue.record("Expected validation to preserve the public resource-limit error.")
    } catch VellumError.resourceLimitExceeded(let message) {
        #expect(message.contains("per-entry"))
    }
}

@Test func ZIPSubsystemRejectsAggregateDeclarationsAboveBudget() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-aggregate-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("aggregate.epub")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try ZipArchiveWriter.write(
        entries: (0..<3).map { index in
            .init(
                path: "payload\(index).bin",
                data: Data(repeating: UInt8(index), count: 400),
                compressionMethod: .store
            )
        },
        to: archiveURL
    )

    // Each entry is within the 1024-byte per-entry cap, but the 1200-byte total
    // exceeds the 1000-byte aggregate budget.
    let limits = ZIPResourceLimits(maxEntryByteCount: 1024, maxTotalByteCount: 1000)
    do {
        _ = try ZipArchiveReader(url: archiveURL, limits: limits)
        Issue.record("Expected the aggregate uncompressed budget to reject the archive.")
    } catch ZipArchiveError.resourceLimitExceeded(let message) {
        #expect(message.contains("aggregate"))
    }
}

@Test func ZIPSubsystemRejectsEntryAboveConfiguredLimit() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-perentry-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("perentry.epub")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try ZipArchiveWriter.write(
        entries: [
            .init(path: "payload.bin", data: Data(repeating: 0x7A, count: 1025), compressionMethod: .store)
        ],
        to: archiveURL
    )

    do {
        _ = try ZipArchiveReader(
            url: archiveURL,
            limits: ZIPResourceLimits(maxEntryByteCount: 1024, maxTotalByteCount: 4096)
        )
        Issue.record("Expected an entry above the configured per-entry limit to be rejected.")
    } catch ZipArchiveError.resourceLimitExceeded {
        // Expected.
    }
}

@Test func ZIPSubsystemAcceptsDeclarationsAtBudgetBoundary() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-boundary-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("boundary.epub")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let payloads = [
        Data(repeating: 0x11, count: 1024),
        Data(repeating: 0x22, count: 1024)
    ]
    try ZipArchiveWriter.write(
        entries: payloads.enumerated().map { index, payload in
            .init(path: "payload\(index).bin", data: payload, compressionMethod: .store)
        },
        to: archiveURL
    )

    // Exactly at both the per-entry cap (1024) and the aggregate budget (2048).
    let limits = ZIPResourceLimits(maxEntryByteCount: 1024, maxTotalByteCount: 2048)
    let reader = try ZipArchiveReader(url: archiveURL, limits: limits)
    #expect(reader.entries.count == 2)

    let restored = try reader.entries.map { try reader.data(for: $0) }
    #expect(restored == payloads)
}

@Test func ZIPSubsystemReaderWithCustomLimitsRoundTripsStoredAndDeflatedEntries() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-custom-limits-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("custom.epub")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let storedPayload = Data("stored entry payload".utf8)
    let deflatedPayload = Data(String(repeating: "deflated entry payload ", count: 32).utf8)

    try ZipArchiveWriter.write(
        entries: [
            .init(path: "stored.txt", data: storedPayload, compressionMethod: .store),
            .init(path: "deflated.txt", data: deflatedPayload, compressionMethod: .deflate)
        ],
        to: archiveURL
    )

    let limits = ZIPResourceLimits(maxEntryByteCount: 4096, maxTotalByteCount: 8192)
    let reader = try ZipArchiveReader(url: archiveURL, limits: limits)
    let storedEntry = try #require(reader.entries.first(where: { $0.path == "stored.txt" }))
    let deflatedEntry = try #require(reader.entries.first(where: { $0.path == "deflated.txt" }))

    #expect(storedEntry.compressionMethod == .store)
    #expect(deflatedEntry.compressionMethod == .deflate)
    #expect(try reader.data(for: storedEntry) == storedPayload)
    #expect(try reader.data(for: deflatedEntry) == deflatedPayload)
}

@Test func ZIPSubsystemDataForRejectsForgedOversizedEntry() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-zip-forged-\(UUID().uuidString)")
    let archiveURL = workspace.appendingPathComponent("forged.epub")

    defer {
        try? FileManager.default.removeItem(at: workspace)
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try ZipArchiveWriter.write(
        entries: [
            .init(path: "payload.txt", data: Data("tiny".utf8), compressionMethod: .store)
        ],
        to: archiveURL
    )

    let reader = try ZipArchiveReader(url: archiveURL)
    let legitimate = try #require(reader.entries.first)
    let forged = ZipEntry(
        path: legitimate.path,
        compressionMethod: .store,
        crc32: legitimate.crc32,
        compressedSize: legitimate.compressedSize,
        uncompressedSize: 1_073_741_824,
        localHeaderOffset: legitimate.localHeaderOffset,
        dataOffset: legitimate.dataOffset
    )

    do {
        _ = try reader.data(for: forged)
        Issue.record("Expected a forged oversized entry to be rejected before extraction.")
    } catch ZipArchiveError.resourceLimitExceeded {
        // Expected.
    }
}

@Test func ZIPSubsystemInflateRejectsOversizedAndNegativeExpectedSize() throws {
    let payload = Data(repeating: 0x41, count: 4096)
    let compressed = try ZipDeflate.compress(payload)

    do {
        _ = try ZipInflate.decompress(compressed, expectedSize: 10_000, maxOutputBytes: 16)
        Issue.record("Expected an oversized expectedSize to be rejected before reservation.")
    } catch ZipArchiveError.resourceLimitExceeded(let message) {
        #expect(message.contains("output limit"))
    }

    do {
        _ = try ZipInflate.decompress(compressed, expectedSize: -1, maxOutputBytes: 16)
        Issue.record("Expected a negative expectedSize to be rejected before reservation.")
    } catch ZipArchiveError.invalidArchive(let message) {
        #expect(message.contains("negative"))
    }
}

@Test func ZIPSubsystemInflateEnforcesRuntimeCapWithoutExpectedSize() throws {
    let payload = Data(repeating: 0x42, count: 4096)
    let compressed = try ZipDeflate.compress(payload)

    do {
        _ = try ZipInflate.decompress(compressed, expectedSize: nil, maxOutputBytes: 16)
        Issue.record("Expected the runtime output cap to reject the stream when expectedSize is nil.")
    } catch ZipArchiveError.resourceLimitExceeded {
        // Expected.
    }

    // Exactly at the output cap still round-trips.
    let exact = Data(repeating: 0x43, count: 64)
    let exactCompressed = try ZipDeflate.compress(exact)
    #expect(try ZipInflate.decompress(exactCompressed, expectedSize: 64, maxOutputBytes: 64) == exact)
}

@Test func ZIPSubsystemRejectsStoredPayloadLargerThanDeclaration() throws {
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellum-zip-stored-size-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: archiveURL) }
    try ZipArchiveWriter.write(
        entries: [.init(path: "payload.bin", data: Data(repeating: 0x41, count: 128), compressionMethod: .store)],
        to: archiveURL
    )
    try rewriteCentralDirectoryUncompressedSize(at: archiveURL, entryIndex: 0, to: 1)
    let reader = try ZipArchiveReader(
        url: archiveURL,
        limits: ZIPResourceLimits(maxEntryByteCount: 16, maxTotalByteCount: 16)
    )
    let entry = try #require(reader.entries.first)
    do {
        _ = try reader.data(for: entry)
        Issue.record("Expected inconsistent stored sizes to fail before copying the payload.")
    } catch ZipArchiveError.invalidArchive(let message) {
        #expect(message.contains("inconsistent sizes"))
    }
}

private func rewriteCentralDirectoryUncompressedSize(at archiveURL: URL, entryIndex: Int, to value: UInt32) throws {
    var data = try Data(contentsOf: archiveURL)
    let signature = Data([0x50, 0x4b, 0x01, 0x02])
    var searchStart = data.startIndex
    var recordsRemaining = entryIndex
    var recordOffset: Int?

    while let range = data.range(of: signature, in: searchStart..<data.endIndex) {
        if recordsRemaining == 0 {
            recordOffset = range.lowerBound
            break
        }
        recordsRemaining -= 1
        searchStart = range.upperBound
    }

    guard let recordOffset else {
        throw ZipArchiveError.invalidArchive("Test fixture could not locate central directory record \(entryIndex).")
    }

    let fieldOffset = recordOffset + 24
    guard fieldOffset >= 0, fieldOffset + 4 <= data.count else {
        throw ZipArchiveError.invalidArchive("Test fixture central directory record is truncated.")
    }

    data[fieldOffset] = UInt8(truncatingIfNeeded: value)
    data[fieldOffset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    data[fieldOffset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    data[fieldOffset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    try data.write(to: archiveURL)
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

/// The owner chose limits that still open media-heavy EPUB 3 books (narration
/// tracks, video) while bounding hostile archives.
@Test func ZIPSubsystemDefaultLimitsAllowMediaHeavyPublications() {
    #expect(ZIPResourceLimits.default.maxEntryByteCount == 512 * 1024 * 1024)
    #expect(ZIPResourceLimits.default.maxTotalByteCount == 2 * 1024 * 1024 * 1024)
}
