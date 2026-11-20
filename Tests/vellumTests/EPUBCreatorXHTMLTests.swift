import Foundation
import Testing
@testable import vellum

// A book whose formatting must survive packaging: its own stylesheet, classes,
// ids, a pop-up footnote and a numeric character reference.
private let styledChapter = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
<head><meta charset="utf-8"/><title>Genesis 1</title><link rel="stylesheet" type="text/css" href="book.css"/></head>
<body>
<div class="book" id="bk01"><div class="chapter" id="ch01001">
<p class="cn">Genesis 1</p>
<p class="pf"><span class="ver-f" id="v01001001">1</span>In the beginning<a class="fnref" epub:type="noteref" href="#fn1">a</a> when God created the heavens&#160;and the earth,</p>
</div></div>
<aside epub:type="footnote" id="fn1" class="footnote"><p class="fn">Or <i>In the beginning God created</i></p></aside>
</body>
</html>
"""

private func xhtmlDocument(_ title: String, body: String = "<p>Text</p>") -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head><body>\(body)</body></html>
    """
}

private func makeStyledRequest(
    chapters: [EPUBChapterInput]? = nil,
    assets: [EPUBAsset]? = nil,
    landmarks: [EPUBLandmark]? = [EPUBLandmark(type: "bodymatter", title: "Genesis 1", href: "a0001.xhtml#ch01001")],
    pageList: Bool = false
) -> CreateRequest {
    CreateRequest(
        metadata: EPUBMetadata(
            identifier: "urn:uuid:7d3c0e6e-4d5e-4f5a-9c39-0c1f2a3b4c5d",
            title: "Styled Book",
            creator: "Vellum Tests",
            language: "en-US",
            subjects: ["BIB016000 BIBLES / General", "REL006880 RELIGION"],
            source: "urn:isbn:9780310461494"
        ),
        chapters: chapters ?? [
            EPUBChapterInput(id: "a0000", title: "Opening Credits", xhtml: xhtmlDocument("Opening Credits"), fileName: "a0000.xhtml"),
            EPUBChapterInput(id: "a0001", title: "Genesis 1", xhtml: styledChapter, fileName: "a0001.xhtml"),
            EPUBChapterInput(id: "x1", title: "Maps", xhtml: xhtmlDocument("Maps"), fileName: "x1-maps.xhtml",
                             linear: false, includeInNavigation: false),
        ],
        assets: assets ?? [
            EPUBAsset(id: "book-css", relativePath: "book.css", mediaType: "text/css", data: Data(".cn { font-weight: bold; }".utf8)),
            EPUBAsset(id: "cover", relativePath: "images/cover.jpg", mediaType: "image/jpeg",
                      data: Data([0xFF, 0xD8, 0xFF, 0xD9]), properties: ["cover-image"]),
        ],
        landmarks: landmarks,
        includeGeneratedPageList: pageList
    )
}

private func withCreatedEPUB<T>(_ request: CreateRequest, _ body: (URL, ZipArchiveReader) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-xhtml-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: url) }
    try EPUBCreator().createEPUB(request, outputURL: url)
    return try body(url, try ZipArchiveReader(url: url))
}

private func entryText(_ reader: ZipArchiveReader, _ path: String) throws -> String {
    let entry = try #require(reader.entries.first { $0.path == path })
    return String(decoding: try reader.data(for: entry), as: UTF8.self)
}

private func diagnosticCodes(_ request: CreateRequest) -> [String] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-xhtml-bad-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        try EPUBCreator().createEPUB(request, outputURL: url)
        return []
    } catch let VellumError.strictValidationFailed(diagnostics) {
        return diagnostics.map(\.code)
    } catch {
        return ["unexpected: \(error)"]
    }
}

@Test func xhtmlChaptersArePackagedByteForByte() throws {
    try withCreatedEPUB(makeStyledRequest()) { (_: URL, reader: ZipArchiveReader) throws in
        #expect(try entryText(reader, "OEBPS/a0001.xhtml") == styledChapter)
        // XHTML-only books don't get vellum's Markdown stylesheet.
        #expect(!reader.entries.contains { $0.path == "OEBPS/styles/main.css" })
        #expect(try entryText(reader, "OEBPS/book.css") == ".cn { font-weight: bold; }")
    }
}

@Test func packageCarriesReadingOrderNavigationAndMetadataOptions() throws {
    try withCreatedEPUB(makeStyledRequest()) { _, reader in
        let opf = try entryText(reader, "OEBPS/content.opf")
        #expect(opf.contains(#"<itemref idref="x1" linear="no"/>"#))
        #expect(opf.contains(#"<itemref idref="a0001"/>"#))
        #expect(opf.contains("<dc:subject>BIB016000 BIBLES / General</dc:subject>"))
        #expect(opf.contains("<dc:source>urn:isbn:9780310461494</dc:source>"))
        #expect(opf.contains(#"<meta name="cover" content="cover"/>"#))
        #expect(!opf.contains(#"id="css""#))

        let nav = try entryText(reader, "OEBPS/nav.xhtml")
        #expect(nav.contains(#"<a href="a0001.xhtml">Genesis 1</a>"#))
        #expect(!nav.contains("x1-maps.xhtml"))
        #expect(nav.contains(#"<a epub:type="bodymatter" href="a0001.xhtml#ch01001">Genesis 1</a>"#))
        #expect(!nav.contains("page-list"))

        let ncx = try entryText(reader, "OEBPS/toc.ncx")
        #expect(!ncx.contains("x1-maps.xhtml"))
        #expect(ncx.contains(#"playOrder="2""#) && !ncx.contains(#"playOrder="3""#))
    }
}

@Test func parserReadsBackLinearSubjectsAndSource() throws {
    try withCreatedEPUB(makeStyledRequest()) { url, _ in
        let book = try EPUBParser().parseEPUB(at: url)
        #expect(book.spine.map(\.linear) == [true, true, false])
        #expect(book.metadata.subjects == ["BIB016000 BIBLES / General", "REL006880 RELIGION"])
        #expect(book.metadata.source == "urn:isbn:9780310461494")
        #expect(book.coverItemID == "cover")
        #expect(book.toc.map(\.label) == ["Opening Credits", "Genesis 1"])
        #expect(EPUBValidator().validateEPUB(at: url).isValid)
    }
}

@Test func markdownBooksKeepTheirDefaultsAlongsideNewOptions() throws {
    let request = CreateRequest(
        metadata: EPUBMetadata(identifier: "urn:uuid:1", title: "Markdown", creator: "Tests"),
        chapters: [
            EPUBChapterInput(id: "c1", title: "One", markdown: "# One\n\nText", fileName: "c1.xhtml"),
            EPUBChapterInput(id: "c2", title: "Two", xhtml: xhtmlDocument("Two"), fileName: "text/c2.xhtml"),
        ]
    )
    try withCreatedEPUB(request) { _, reader in
        #expect(reader.entries.contains { $0.path == "OEBPS/styles/main.css" })
        let nav = try entryText(reader, "OEBPS/nav.xhtml")
        #expect(nav.contains("page-list"))
        #expect(nav.contains(#"<a epub:type="bodymatter" href="c1.xhtml">Start</a>"#))
        #expect(try entryText(reader, "OEBPS/text/c2.xhtml") == xhtmlDocument("Two"))
    }
}

@Test func creatorRejectsMalformedXHTMLBeforeWriting() {
    let broken = EPUBChapterInput(id: "a0000", title: "Broken", xhtml: "<html><body><p>open</body></html>", fileName: "a0000.xhtml")
    #expect(diagnosticCodes(makeStyledRequest(chapters: [broken], landmarks: nil)) == ["CRT004"])
    let truncated = EPUBChapterInput(id: "a0000", title: "Truncated", xhtml: "<html><body>", fileName: "a0000.xhtml")
    #expect(diagnosticCodes(makeStyledRequest(chapters: [truncated], landmarks: nil)) == ["CRT004"])
}

@Test func creatorRejectsUnsafeAndCollidingNames() {
    let escape = EPUBAsset(id: "evil", relativePath: "../../evil.css", mediaType: "text/css", data: Data())
    #expect(diagnosticCodes(makeStyledRequest(assets: [escape])).contains("CRT005"))

    let chapters = [
        EPUBChapterInput(id: "a", title: "A", xhtml: xhtmlDocument("A"), fileName: "Chapter.xhtml"),
        EPUBChapterInput(id: "b", title: "B", xhtml: xhtmlDocument("B"), fileName: "chapter.xhtml"),
    ]
    #expect(diagnosticCodes(makeStyledRequest(chapters: chapters, landmarks: nil)).contains("CRT002"))

    let sameID = [
        EPUBChapterInput(id: "nav", title: "A", xhtml: xhtmlDocument("A"), fileName: "a.xhtml"),
    ]
    #expect(diagnosticCodes(makeStyledRequest(chapters: sameID, landmarks: nil)).contains("CRT006"))

    let generated = [
        EPUBChapterInput(id: "a", title: "A", xhtml: xhtmlDocument("A"), fileName: "NAV.xhtml"),
    ]
    #expect(diagnosticCodes(makeStyledRequest(chapters: generated, landmarks: nil)).contains("CRT007"))
}

@Test func creatorRejectsDanglingLandmarksAndEmptyNavigation() {
    let dangling = [EPUBLandmark(type: "bodymatter", title: "Nowhere", href: "missing.xhtml")]
    #expect(diagnosticCodes(makeStyledRequest(landmarks: dangling)) == ["CRT008"])

    let hidden = [
        EPUBChapterInput(id: "a", title: "A", xhtml: xhtmlDocument("A"), fileName: "a.xhtml",
                         linear: false, includeInNavigation: false),
    ]
    #expect(Set(diagnosticCodes(makeStyledRequest(chapters: hidden, landmarks: []))) == ["CRT009", "CRT010"])
}

@Test func modelsDecodeValuesEncodedBeforeTheNewFields() throws {
    let chapter = try JSONDecoder().decode(
        EPUBChapterInput.self,
        from: Data(##"{"id":"c1","title":"One","markdown":"# One","fileName":"c1.xhtml"}"##.utf8)
    )
    #expect(chapter.linear && chapter.includeInNavigation && chapter.xhtml == nil && chapter.properties.isEmpty)

    let spine = try JSONDecoder().decode(EPUBSpineItem.self, from: Data(#"{"idref":"c1"}"#.utf8))
    #expect(spine.linear)

    let encoded = try JSONEncoder().encode(EPUBMetadata(identifier: "id", title: "T", creator: "C"))
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "subjects")
    let metadata = try JSONDecoder().decode(EPUBMetadata.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(metadata.subjects.isEmpty && metadata.source == nil)
}

@Test func buildManifestReadsFilesRelativeToItself() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-manifest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("text"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(styledChapter.utf8).write(to: dir.appendingPathComponent("text/a0001.xhtml"))
    try Data("# Notes\n\nLater.".utf8).write(to: dir.appendingPathComponent("notes.md"))
    try Data(".cn{}".utf8).write(to: dir.appendingPathComponent("book.css"))
    let json = """
    {
      "metadata": { "identifier": "urn:uuid:2", "title": "From Manifest", "creator": "Tests",
                    "modified": "2026-11-19T20:00:00Z", "subjects": ["One"] },
      "chapters": [
        { "id": "a0001", "title": "Genesis 1", "fileName": "a0001.xhtml", "xhtmlFile": "text/a0001.xhtml" },
        { "id": "notes", "title": "Notes", "fileName": "notes.xhtml", "markdownFile": "notes.md",
          "linear": false, "includeInNavigation": false }
      ],
      "assets": [ { "id": "book-css", "relativePath": "book.css", "mediaType": "text/css", "file": "book.css" } ],
      "includeGeneratedPageList": false
    }
    """
    let manifestURL = dir.appendingPathComponent("book.json")
    try Data(json.utf8).write(to: manifestURL)

    let request = try EPUBBuildManifest.load(from: manifestURL).makeRequest(relativeTo: dir)
    #expect(request.chapters.map(\.id) == ["a0001", "notes"])
    #expect(request.chapters[0].xhtml == styledChapter)
    #expect(request.chapters[1].markdown.contains("Later.") && !request.chapters[1].linear)
    #expect(request.metadata.subjects == ["One"])
    #expect(request.metadata.modified == ISO8601DateFormatter().date(from: "2026-11-19T20:00:00Z"))
    #expect(!request.includeGeneratedPageList)
    try withCreatedEPUB(request) { (url: URL, _: ZipArchiveReader) throws in
        #expect(try EPUBParser().parseEPUB(at: url).spine.map(\.linear) == [true, false])
    }
}

@Test func buildManifestNamesMissingContent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-manifest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = #"{"metadata":{"identifier":"u","title":"T","creator":"C"},"chapters":[{"id":"a","title":"A","fileName":"a.xhtml"}]}"#
    let manifestURL = dir.appendingPathComponent("book.json")
    try Data(json.utf8).write(to: manifestURL)
    #expect(throws: VellumError.self) { try EPUBBuildManifest.load(from: manifestURL).makeRequest(relativeTo: dir) }

    try Data(#"{"metadata":{"title":"T"},"chapters":[]}"#.utf8).write(to: manifestURL)
    do {
        _ = try EPUBBuildManifest.load(from: manifestURL)
        Issue.record("expected MAN001")
    } catch let VellumError.strictValidationFailed(diagnostics) {
        #expect(diagnostics.map(\.code) == ["MAN001"])
        #expect(diagnostics[0].message.contains("metadata.identifier"))
    }
}

@Test func creatorRejectsNamedEntitiesAndNonUTF8Declarations() {
    func codes(_ xhtml: String) -> [String] {
        diagnosticCodes(makeStyledRequest(
            chapters: [EPUBChapterInput(id: "a", title: "A", xhtml: xhtml, fileName: "a.xhtml")], landmarks: nil))
    }
    // EPUB 3 XHTML has no DTD: only XML's five entities are defined.
    #expect(codes(xhtmlDocument("A", body: "<p>heavens&nbsp;and</p>")) == ["CRT004"])
    #expect(codes(xhtmlDocument("A", body: "<p>Tom &amp; Jerry &#160; &lt;3</p>")) == [])
    // The chapter is written as UTF-8, so it may only declare UTF-8.
    let latin1 = xhtmlDocument("A").replacingOccurrences(of: #"encoding="UTF-8""#, with: #"encoding="ISO-8859-1""#)
    #expect(codes(latin1) == ["CRT004"])
}

@Test func creatorReportsEachNameProblemOnItsOwn() {
    func codes(chapters: [EPUBChapterInput], assets: [EPUBAsset] = []) -> Set<String> {
        Set(diagnosticCodes(makeStyledRequest(chapters: chapters, assets: assets, landmarks: nil)))
    }
    let ok = EPUBChapterInput(id: "a", title: "A", xhtml: xhtmlDocument("A"), fileName: "a.xhtml")
    #expect(codes(chapters: [EPUBChapterInput(id: "a", title: "A", xhtml: xhtmlDocument("A"), fileName: "../a.xhtml")]) == ["CRT003"])
    #expect(codes(chapters: [EPUBChapterInput(id: "a", title: "A", xhtml: xhtmlDocument("A"), fileName: "c:a.xhtml")]) == ["CRT003"])
    // A colon after the first slash is an ordinary character.
    #expect(codes(chapters: [ok], assets: [EPUBAsset(id: "img", relativePath: "images/a:b.png", mediaType: "image/png", data: Data())]) == [])
    // A path can't be a file and a folder.
    #expect(codes(chapters: [EPUBChapterInput(id: "a", title: "A", xhtml: xhtmlDocument("A"), fileName: "images")],
                  assets: [EPUBAsset(id: "img", relativePath: "images/a.png", mediaType: "image/png", data: Data())]) == ["CRT002"])
    #expect(codes(chapters: [EPUBChapterInput(id: "1st", title: "A", xhtml: xhtmlDocument("A"), fileName: "a.xhtml")]) == ["CRT006"])
    #expect(codes(chapters: [EPUBChapterInput(id: "a b", title: "A", xhtml: xhtmlDocument("A"), fileName: "a.xhtml")]) == ["CRT006"])
    #expect(codes(chapters: [EPUBChapterInput(id: "a", title: "  ", xhtml: xhtmlDocument("A"), fileName: "a.xhtml")]) == ["CRT009"])
    #expect(codes(chapters: [EPUBChapterInput(id: "a", title: "A", xhtml: xhtmlDocument("A"), fileName: "a.xhtml", properties: ["nav"])]) == ["CRT011"])
    let cover = { (id: String) in EPUBAsset(id: id, relativePath: "\(id).jpg", mediaType: "image/jpeg", data: Data(), properties: ["cover-image"]) }
    #expect(codes(chapters: [ok], assets: [cover("c1"), cover("c2")]) == ["CRT011"])
}

@Test func markdownBooksCantReplaceTheGeneratedStylesheet() {
    // This used to write the asset over styles/main.css and list the file twice in the manifest.
    let request = CreateRequest(
        metadata: EPUBMetadata(identifier: "urn:uuid:3", title: "Markdown", creator: "Tests"),
        chapters: [EPUBChapterInput(id: "c1", title: "One", markdown: "# One", fileName: "c1.xhtml")],
        assets: [EPUBAsset(id: "mycss", relativePath: "styles/main.css", mediaType: "text/css", data: Data())]
    )
    #expect(diagnosticCodes(request) == ["CRT007"])
}

@Test func landmarkTargetsAndDefaults() throws {
    for href in ["", "#frag", "missing.xhtml#x"] {
        #expect(diagnosticCodes(makeStyledRequest(landmarks: [EPUBLandmark(type: "bodymatter", title: "X", href: href)])) == ["CRT008"])
    }
    try withCreatedEPUB(makeStyledRequest(landmarks: [])) { (_: URL, reader: ZipArchiveReader) throws in
        #expect(!(try entryText(reader, "OEBPS/nav.xhtml")).contains("landmarks"))
    }
    // The default Start landmark skips chapters outside the reading order.
    let chapters = [
        EPUBChapterInput(id: "notes", title: "Notes", xhtml: xhtmlDocument("Notes"), fileName: "notes.xhtml", linear: false),
        EPUBChapterInput(id: "c1", title: "One", xhtml: xhtmlDocument("One"), fileName: "c1.xhtml"),
    ]
    try withCreatedEPUB(makeStyledRequest(chapters: chapters, landmarks: nil)) { (_: URL, reader: ZipArchiveReader) throws in
        #expect(try entryText(reader, "OEBPS/nav.xhtml").contains(#"<a epub:type="bodymatter" href="c1.xhtml">Start</a>"#))
    }
}
