import Foundation
import Testing
@testable import vellum

@Test func editablePublicationRoundTripSaveAndParse() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let editor = EPUBPublicationEditor()
    let parser = EPUBParser()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-editable-source-\(UUID().uuidString).epub")
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-editable-output-\(UUID().uuidString).epub")
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    try creator.createEPUB(request, outputURL: sourceURL)
    let editable = try service.openEditable(url: sourceURL)
    let updated = try editor.apply(
        .updateChapter(
            id: "chapter-1",
            xhtml: """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Chapter 1</title></head>
            <body><section epub:type="chapter"><h1>Chapter 1</h1><p>Edited content.</p></section></body>
            </html>
            """,
            title: "Edited Chapter 1"
        ),
        to: editable
    )

    try service.save(updated, to: outputURL)
    let reparsed = try parser.parseEPUB(at: outputURL)

    #expect(reparsed.chapters.count == 2)
    #expect(reparsed.chapters[0].plainText.contains("Edited content."))
    #expect(reparsed.toc.first?.label == "Edited Chapter 1")
}

@Test func editablePublicationCanInsertAndMoveChapter() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let editor = EPUBPublicationEditor()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-editable-order-source-\(UUID().uuidString).epub")
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-editable-order-output-\(UUID().uuidString).epub")
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    try creator.createEPUB(request, outputURL: sourceURL)
    var editable = try service.openEditable(url: sourceURL)
    editable = try editor.apply(
        .insertChapter(
            index: 1,
            chapter: EditableChapter(
                id: "chapter-new",
                href: "chapter-new.xhtml",
                title: "Inserted",
                xhtml: """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Inserted</title></head><body><p>Inserted.</p></body></html>
                """
            )
        ),
        to: editable
    )
    editable = try editor.apply(.moveChapter(id: "chapter-new", toIndex: 0), to: editable)

    try service.save(editable, to: outputURL)
    let publication = try service.open(url: outputURL)
    #expect(publication.readingOrder.count == 3)
    #expect(publication.readingOrder.first?.id == "chapter-new")
}

@Test func editablePublicationRejectsDuplicateResourceIDs() throws {
    let editor = EPUBPublicationEditor()
    let metadata = EPUBMetadata(identifier: "urn:uuid:\(UUID().uuidString)", title: "Test", creator: "Tester")
    let editable = EditablePublication(
        metadata: metadata,
        chapters: [
            EditableChapter(
                id: "chapter-1",
                href: "chapter1.xhtml",
                title: "One",
                xhtml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>One</p></body></html>"
            )
        ],
        assets: []
    )

    do {
        _ = try editor.apply(
            .addAsset(
                EditableAsset(
                    id: "chapter-1",
                    href: "styles/main.css",
                    mediaType: "text/css",
                    data: Data("body{}".utf8)
                )
            ),
            to: editable
        )
        Issue.record("Expected duplicate id rejection.")
    } catch let VellumError.strictValidationFailed(diags) {
        #expect(diags.contains(where: { $0.code == "EDT006" }))
    }
}

@Test func editableSavePreservesUnknownOPFMetadataEntries() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-preserve-meta-source-\(UUID().uuidString).epub")
    let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-preserve-meta-dir-\(UUID().uuidString)")
    let patchedURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-preserve-meta-patched-\(UUID().uuidString).epub")
    let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-preserve-meta-outdir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: sourceDir)
        try? FileManager.default.removeItem(at: patchedURL)
        try? FileManager.default.removeItem(at: outputDir)
    }

    try creator.createEPUB(request, outputURL: sourceURL)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", sourceURL.path, "-d", sourceDir.path])

    let opfURL = sourceDir.appendingPathComponent("OEBPS/content.opf")
    var opf = try String(contentsOf: opfURL, encoding: .utf8)
    opf = opf.replacingOccurrences(
        of: "</metadata>",
        with: "<meta property=\"rendition:layout\">pre-paginated</meta>\n  </metadata>"
    )
    try Data(opf.utf8).write(to: opfURL)

    try run("/usr/bin/zip", ["-X0q", patchedURL.path, "mimetype"], cwd: sourceDir)
    try run("/usr/bin/zip", ["-Xr9q", patchedURL.path, "META-INF", "OEBPS"], cwd: sourceDir)

    let editable = try service.openEditable(url: patchedURL)
    let savedData = try service.save(editable)
    let savedURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-preserve-meta-saved-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: savedURL) }
    try savedData.write(to: savedURL)

    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", savedURL.path, "-d", outputDir.path])
    let savedOPF = try String(contentsOf: outputDir.appendingPathComponent("OEBPS/content.opf"), encoding: .utf8)
    #expect(savedOPF.contains(#"<meta property="rendition:layout">pre-paginated</meta>"#))
}

@Test func editableSaveRendersNestedNavigationOverrideAndFallbacks() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let editor = EPUBPublicationEditor()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-override-source-\(UUID().uuidString).epub")
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-override-out-\(UUID().uuidString).epub")
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-nav-override-dir-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: outDir)
    }

    try creator.createEPUB(request, outputURL: sourceURL)
    var editable = try service.openEditable(url: sourceURL)
    editable = try editor.apply(
        .setNavigationOverride(
            NavigationTree(
                toc: [
                    NavigationItem(
                        label: "Part 1",
                        href: "chapter1.xhtml",
                        children: [NavigationItem(label: "Scene A", href: "chapter2.xhtml")]
                    )
                ],
                landmarks: [],
                pageList: []
            )
        ),
        to: editable
    )

    try service.save(editable, to: outputURL)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try run("/usr/bin/unzip", ["-q", outputURL.path, "-d", outDir.path])
    let nav = try String(contentsOf: outDir.appendingPathComponent("OEBPS/nav.xhtml"), encoding: .utf8)
    #expect(nav.contains("Part 1"))
    #expect(nav.contains("Scene A"))
    #expect(nav.contains("<ol>"))
    #expect(nav.contains("Page 1"))
    #expect(nav.contains("Start"))
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
