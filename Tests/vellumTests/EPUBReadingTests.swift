import Foundation
import Testing
@testable import vellum

// MARK: - Navigation resolution and hierarchy (#105, #110)

@Test func subfolderNavResolvesPathsAndPreservesHierarchy() throws {
    try withReadingFixture { fixture in
        try fixture.move("OEBPS/chapter1.xhtml", to: "OEBPS/Text/Section0001.xhtml")
        try fixture.move("OEBPS/chapter2.xhtml", to: "OEBPS/Text/Section0002.xhtml")
        try fixture.rewrite("OEBPS/content.opf") {
            $0.replacingOccurrences(of: "chapter1.xhtml", with: "Text/Section0001.xhtml")
                .replacingOccurrences(of: "chapter2.xhtml", with: "Text/Section0002.xhtml")
                .replacingOccurrences(of: "nav.xhtml", with: "Text/nav.xhtml")
        }
        try fixture.move("OEBPS/nav.xhtml", to: "OEBPS/Text/nav.xhtml")
        try fixture.write("OEBPS/Text/nav.xhtml", text: navigationXML("""
        <li><a href="Section0001.xhtml#start">Part One</a><ol>
          <li><a href="./Section0001.xhtml#section">First Section</a><ol>
            <li><a href="../Text/Section0002.xhtml">Second Chapter</a></li>
          </ol></li>
        </ol></li>
        """))

        let book = try EPUBParser().parseEPUB(at: fixture.archive())
        #expect(book.toc.map(\.href) == ["Text/Section0001.xhtml#start", "Text/Section0001.xhtml#section", "Text/Section0002.xhtml"])
        #expect(book.toc.map(\.level) == [0, 1, 2])
        #expect(book.chapters.map(\.title) == ["Part One", "Second Chapter"])
        #expect(book.chapters.map(\.href) == ["Text/Section0001.xhtml", "Text/Section0002.xhtml"])
        #expect(book.diagnostics.isEmpty)
    }
}

@Test(arguments: ["Chapter%201.xhtml", "Chapter 1.xhtml"])
func percentEncodedTOCTargetUsesManifestSpelling(manifestHref: String) throws {
    try withReadingFixture { fixture in
        try fixture.move("OEBPS/chapter1.xhtml", to: "OEBPS/Chapter 1.xhtml")
        try fixture.rewrite("OEBPS/content.opf") { $0.replacingOccurrences(of: "chapter1.xhtml", with: manifestHref) }
        try fixture.write("OEBPS/nav.xhtml", text: navigationXML("""
        <li><a href="Chapter%201.xhtml#first">Named Chapter</a></li>
        <li><a href="Chapter%201.xhtml#second">Later Section</a></li>
        <li><a href="chapter2.xhtml">Second</a></li>
        """))
        let book = try EPUBParser().parseEPUB(at: fixture.archive())
        #expect(book.toc[0].href == manifestHref + "#first")
        #expect(book.toc[1].href == manifestHref + "#second")
        #expect(book.chapters[0].href == manifestHref)
        #expect(book.chapters[0].title == "Named Chapter")
        #expect(book.chapters[0].plainText.contains("Lorem ipsum"))
    }
}

@Test func fragmentOnlyAndExternalTOCLinksRemainValid() throws {
    try withReadingFixture { fixture in
        try fixture.write("OEBPS/nav.xhtml", text: navigationXML("""
        <li><a href="#contents">Contents</a></li>
        <li><a href="https://example.com/book">Book Website</a></li>
        <li><a href="mailto:author@example.com">Author</a></li>
        <li><a href="chapter1.xhtml#first">First Chapter</a></li>
        """))
        let book = try EPUBParser().parseEPUB(at: fixture.archive())
        #expect(book.toc.map(\.href) == ["nav.xhtml#contents", "https://example.com/book", "mailto:author@example.com", "chapter1.xhtml#first"])
        #expect(book.chapters[0].title == "First Chapter")
        #expect(book.diagnostics.isEmpty)
    }
}

@Test func subfolderNCXResolvesNestedPointsInDocumentOrder() throws {
    try withReadingFixture { fixture in
        try fixture.removeNav(useEPUB2: true)
        try fixture.move("OEBPS/toc.ncx", to: "OEBPS/Navigation/toc.ncx")
        try fixture.rewrite("OEBPS/content.opf") { $0.replacingOccurrences(of: "toc.ncx", with: "Navigation/toc.ncx") }
        try fixture.write("OEBPS/Navigation/toc.ncx", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
          <navPoint id="part"><navLabel><text>Part &amp; One</text></navLabel><content src="../chapter1.xhtml#part"/>
            <navPoint id="section"><navLabel><text>Section</text></navLabel><content src="../chapter1.xhtml#section"/></navPoint>
          </navPoint>
          <navPoint id="second"><navLabel><text>Second</text></navLabel><content src="../chapter2.xhtml"/></navPoint>
        </navMap></ncx>
        """)
        let book = try EPUBParser().parseEPUB(at: fixture.archive())
        #expect(book.toc.map(\.label) == ["Part & One", "Section", "Second"])
        #expect(book.toc.map(\.href) == ["chapter1.xhtml#part", "chapter1.xhtml#section", "chapter2.xhtml"])
        #expect(book.toc.map(\.level) == [0, 1, 0])
        #expect(book.chapters.map(\.title) == ["Part & One", "Second"])
    }
}

@Test func resolvedSubfolderNavigationSurvivesPublicationEditingRoundTrip() throws {
    try withReadingFixture { fixture in
        try fixture.move("OEBPS/nav.xhtml", to: "OEBPS/Text/nav.xhtml")
        try fixture.rewrite("OEBPS/content.opf") { $0.replacingOccurrences(of: "nav.xhtml", with: "Text/nav.xhtml") }
        try fixture.write("OEBPS/Text/nav.xhtml", text: navigationXML("""
        <li><a href="../chapter1.xhtml#start">First</a></li>
        <li><a href="../chapter2.xhtml">Second</a></li>
        """))
        let service = EPUBPublicationService()
        let source = try fixture.archive()
        let publication = try service.open(url: source).publication
        #expect(publication.navigation.toc.map(\.href) == ["chapter1.xhtml#start", "chapter2.xhtml"])
        let editable = try service.openEditable(url: source)
        let navigation = NavigationTree(toc: publication.navigation.toc)
        let updated = try EPUBPublicationEditor().apply(.setNavigationOverride(navigation), to: editable)
        let saved = fixture.directory.appendingPathComponent("saved.epub")
        try service.save(updated, to: saved)
        let book = try EPUBParser().parseEPUB(at: saved)
        // The writer puts nav.xhtml beside the OPF, so OPF-relative links stay valid.
        #expect(book.toc.map(\.href) == ["chapter1.xhtml#start", "chapter2.xhtml"])
        #expect(book.chapters.map(\.title) == ["First", "Second"])
    }
}

// MARK: - Encryption (#106)

@Test(arguments: ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"])
func fontObfuscationDoesNotBlockReading(algorithm: String) throws {
    try withReadingFixture { fixture in
        try fixture.write("OEBPS/fonts/Font One.otf", data: Data("obfuscated font bytes".utf8))
        try fixture.rewrite("OEBPS/content.opf") {
            $0.replacingOccurrences(of: "</manifest>", with: #"<item id="font" href="fonts/Font%20One.otf" media-type="font/otf"/></manifest>"#)
        }
        try fixture.write("META-INF/encryption.xml", text: encryptionXML(algorithm: algorithm, uri: "OEBPS/fonts/./Font%20One.otf"))
        for mode in [EPUBParsingMode.strict, .lenient] {
            let book = try EPUBParser(mode: mode).parseEPUB(at: fixture.archive())
            #expect(book.chapters.count == 2)
            #expect(book.chapters[0].plainText.contains("Lorem ipsum"))
        }
    }
}

@Test func emptyEncryptionXMLDoesNotBlockReading() throws {
    try withReadingFixture { fixture in
        try fixture.write("META-INF/encryption.xml", text: #"<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"/>"#)
        let book = try EPUBParser().parseEPUB(at: fixture.archive())
        #expect(book.chapters.count == 2)
    }
}

@Test(arguments: ["OEBPS/chapter1.xhtml", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/content.opf", "OEBPS/./chapter%31.xhtml"])
func encryptionOfRequiredDocumentsIsRejected(uri: String) throws {
    try withReadingFixture { fixture in
        try fixture.write("META-INF/encryption.xml", text: encryptionXML(algorithm: "http://www.w3.org/2001/04/xmlenc#aes128-cbc", uri: uri))
        for mode in [EPUBParsingMode.strict, .lenient] {
            do {
                _ = try EPUBParser(mode: mode).parseEPUB(at: fixture.archive())
                Issue.record("Expected PAR020 for encrypted required document \(uri).")
            } catch let VellumError.unsupportedFeature(reason, diagnostics) {
                #expect(reason.contains("encrypted"))
                #expect(diagnostics.contains { $0.code == "PAR020" && $0.filePath == "META-INF/encryption.xml" })
            }
        }
    }
}

@Test func obfuscatedContentDocumentIsStillUnreadable() throws {
    try withReadingFixture { fixture in
        try fixture.write("META-INF/encryption.xml", text: encryptionXML(algorithm: "http://www.idpf.org/2008/embedding", uri: "OEBPS/chapter1.xhtml"))
        do {
            _ = try EPUBParser(mode: .lenient).parseEPUB(at: fixture.archive())
            Issue.record("Expected PAR020 for an obfuscated content document.")
        } catch let VellumError.unsupportedFeature(reason, diagnostics) {
            #expect(reason.contains("obfuscated"))
            #expect(!reason.contains("encrypted"))
            #expect(diagnostics.contains { $0.code == "PAR020" })
        }
    }
}

@Test(arguments: ["<encryption><broken>", "<invalid/>", #"<encryption xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData/></encryption>"#])
func malformedEncryptionXMLIsRejected(xml: String) throws {
    try withReadingFixture { fixture in
        try fixture.write("META-INF/encryption.xml", text: xml)
        for mode in [EPUBParsingMode.strict, .lenient] {
            do {
                _ = try EPUBParser(mode: mode).parseEPUB(at: fixture.archive())
                Issue.record("Expected conservative PAR020 rejection.")
            } catch let VellumError.unsupportedFeature(_, diagnostics) {
                #expect(diagnostics.contains { $0.code == "PAR020" })
            }
        }
    }
}

// MARK: - Lenient recovery and encoding (#107)

@Test(arguments: ["svg", "missingFont", "missingChapter", "malformedChapter", "missingStructure", "badTOCTarget", "malformedNav", "missingNavFile", "emptyNav", "missingNav", "noNavigation", "malformedNCX"])
func lenientReadingRecoversAndStrictParsingStillRejects(defect: String) throws {
    try withReadingFixture { fixture in
        let code: String
        let path: String
        switch defect {
        case "svg":
            code = "PAR023"
            path = "chapter1.xhtml"
            try fixture.rewrite("OEBPS/content.opf") {
                $0.replacingOccurrences(of: #"id="chapter-1" href="chapter1.xhtml" media-type="application/xhtml+xml""#,
                                        with: #"id="chapter-1" href="chapter1.xhtml" media-type="image/svg+xml""#)
            }
            try fixture.write("OEBPS/chapter1.xhtml", text: #"<svg xmlns="http://www.w3.org/2000/svg"/>"#)
        case "missingFont":
            code = "PAR025"
            path = "fonts/missing.otf"
            try fixture.rewrite("OEBPS/content.opf") {
                $0.replacingOccurrences(of: "</manifest>", with: #"<item id="font" href="fonts/missing.otf" media-type="font/otf"/></manifest>"#)
            }
        case "missingChapter":
            code = "PAR025"
            path = "chapter1.xhtml"
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("OEBPS/chapter1.xhtml"))
        case "malformedChapter":
            code = "PAR029"
            path = "chapter1.xhtml"
            try fixture.write("OEBPS/chapter1.xhtml", text: "<html><body><p>Recover this text.</body></html>")
        case "missingStructure":
            code = "PAR012"
            path = "chapter1.xhtml"
            try fixture.write("OEBPS/chapter1.xhtml", text: "<article><p>Recover this text.</p></article>")
        case "badTOCTarget":
            code = "PAR024"
            path = "nav.xhtml"
            try fixture.rewrite("OEBPS/nav.xhtml") { $0.replacingOccurrences(of: "chapter1.xhtml", with: "missing.xhtml") }
        case "malformedNav":
            code = "PAR026"
            path = "nav.xhtml"
            try fixture.write("OEBPS/nav.xhtml", text: "<html><broken>")
        case "missingNavFile":
            code = "PAR025"
            path = "nav.xhtml"
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("OEBPS/nav.xhtml"))
        case "emptyNav":
            code = "PAR027"
            path = "nav.xhtml"
            try fixture.rewrite("OEBPS/nav.xhtml") { $0.replacingOccurrences(of: "epub:type=\"toc\"", with: "epub:type=\"landmarks\"") }
        case "missingNav":
            code = "PAR039"
            path = "OEBPS/content.opf"
            try fixture.removeNav()
        case "malformedNCX":
            code = "PAR028"
            path = "toc.ncx"
            try fixture.removeNav(useEPUB2: true)
            try fixture.write("OEBPS/toc.ncx", text: "<ncx><navMap>")
        default:
            code = "PAR022"
            path = "OEBPS/content.opf"
            try fixture.removeNav()
            try fixture.rewrite("OEBPS/content.opf") {
                $0.replacingOccurrences(of: #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#, with: "")
            }
        }
        let archive = try fixture.archive()
        do {
            _ = try EPUBParser().parseEPUB(at: archive)
            Issue.record("Strict mode should reject \(defect).")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.contains { $0.code == code })
        }
        let book = try EPUBParser(mode: .lenient).parseEPUB(at: archive)
        #expect(book.chapters.map(\.id) == ["chapter-1", "chapter-2"])
        #expect(book.chapters[1].plainText.contains("Lorem ipsum"))
        #expect(book.diagnostics.contains { $0.code == code && $0.filePath == path })
        #expect(book.diagnostics.allSatisfy { $0.severity == .warning })
        if defect == "svg" || defect == "missingChapter" {
            #expect(book.chapters[0].title == "Chapter 1")
            #expect(book.chapters[0].plainText == "This page can't be displayed.")
        } else if defect == "malformedChapter" || defect == "missingStructure" {
            #expect(book.chapters[0].plainText.contains("Recover this text."))
        }
        if defect == "malformedNav" || defect == "emptyNav" || defect == "missingNav" || defect == "missingNavFile" {
            #expect(book.toc.map(\.label) == ["Chapter 1", "Chapter 2"])
        }
        if defect == "noNavigation" || defect == "malformedNCX" {
            #expect(book.toc.isEmpty)
            #expect(book.chapters[0].title == "chapter-1")
        }
    }
}

@Test(arguments: ["utf8BOM", "utf16LEBOM", "utf16BEBOM", "utf16LEDeclaration", "utf16BEDeclaration"])
func contentAndNavigationDecodeSupportedEncodings(variant: String) throws {
    try withReadingFixture { fixture in
        for path in ["OEBPS/chapter1.xhtml", "OEBPS/nav.xhtml", "OEBPS/toc.ncx"] {
            var text = try String(contentsOf: fixture.root.appendingPathComponent(path), encoding: .utf8)
            let data: Data
            if variant == "utf8BOM" {
                data = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
            } else {
                text = text.replacingOccurrences(of: "UTF-8", with: "UTF-16")
                let bigEndian = variant.contains("BE")
                let bom = variant.hasSuffix("BOM") ? Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) : Data()
                data = bom + (try #require(text.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)))
            }
            try fixture.write(path, data: data)
        }
        for mode in [EPUBParsingMode.strict, .lenient] {
            let book = try EPUBParser(mode: mode).parseEPUB(at: fixture.archive())
            #expect(book.chapters[0].plainText.contains("Lorem ipsum"))
            #expect(book.chapters[0].title == "Chapter 1")
            #expect(book.diagnostics.isEmpty)
        }
        // Also exercise the encoded NCX independently of the nav.
        try fixture.removeNav(useEPUB2: true)
        let ncxBook = try EPUBParser().parseEPUB(at: fixture.archive())
        #expect(ncxBook.toc.map(\.label) == ["Chapter 1", "Chapter 2"])
        #expect(ncxBook.chapters[0].title == "Chapter 1")
    }
}

@Test("The package's stylesheets come with the parsed book, by manifest href")
func parsedBookKeepsStylesheets() throws {
    try withReadingFixture { fixture in
        let book = try EPUBParser().parseEPUB(at: fixture.archive())
        let css = try #require(book.stylesheets["styles/main.css"], "Keys: \(book.stylesheets.keys.sorted())")
        #expect(!css.isEmpty)
        let decoded = try JSONDecoder().decode(EPUBBook.self, from: JSONEncoder().encode(book))
        #expect(decoded.stylesheets == book.stylesheets, "Survives the parse cache")
    }
}

/// Every Kobo EPUB lists `../js/kobo.js` from `OEBPS/`: the in-package
/// `js/kobo.js`, which chapters load with a `<script>` tag (GH #338).
@Test("Resource access never leaves the extracted package, however an href is spelled")
func resourceAccessStaysInsideThePackage() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-contain-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("extracted")
    let opfBase = root.appendingPathComponent("OEBPS")
    try FileManager.default.createDirectory(at: opfBase.appendingPathComponent("a%2fb"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("js"), withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: base.appendingPathComponent("secret.txt"))
    try Data("kobo".utf8).write(to: root.appendingPathComponent("js/kobo.js"))
    let escape = "a%2fb/../../../secret.txt"
    let resources = PublicationResources(rootURL: root, opfBaseURL: opfBase, hrefs: [escape, "../js/kobo.js"], managedRootURL: nil)
    #expect(resources.fileURL(forHref: escape) == nil, "A file outside the package is never served")
    #expect(throws: VellumError.self) { try resources.data(forHref: escape) }
    #expect(try resources.data(forHref: "../js/kobo.js") == Data("kobo".utf8), "An in-package parent path still works")
}

@Test("An in-package ../ manifest href, as in every Kobo EPUB, parses in both modes")
func koboParentDirectoryHrefParses() throws {
    try withReadingFixture { fixture in
        try fixture.write("js/kobo.js", text: "var KOBO_TAG = 'kobo-script-text';")
        try fixture.rewrite("OEBPS/content.opf") {
            $0.replacingOccurrences(
                of: "</manifest>",
                with: #"<item id="js-kobo.js" href="../js/kobo.js" media-type="application/javascript"/></manifest>"#
            )
        }
        try fixture.rewrite("OEBPS/chapter1.xhtml") {
            $0.replacingOccurrences(of: "</head>", with: #"<script src="../js/kobo.js" type="text/javascript"></script></head>"#)
        }
        for mode in [EPUBParsingMode.strict, .lenient] {
            let book = try EPUBParser(mode: mode).parseEPUB(at: fixture.archive(including: ["js"]))
            #expect(!book.diagnostics.contains { $0.code == "PAR030" }, "\(mode)")
            #expect(book.chapters.count == 2, "\(mode)")
            #expect(!book.chapters[0].plainText.contains("kobo-script-text"), "The script is never read as text")
        }
    }
}

/// `a%2fb/../../../x` stays inside when decoded (`a/b/…`) but leaves the
/// package as spelled (one directory named `a%2fb`): either reading rejects.
@Test(arguments: ["manifestTraversal", "encodedTraversal", "encodedSlashTraversal", "containerTraversal", "navTraversal"])
func lenientModeNeverRelaxesPathSafety(defect: String) throws {
    try withReadingFixture { fixture in
        let code = defect == "containerTraversal" ? "PAR031" : "PAR030"
        switch defect {
        case "containerTraversal":
            try fixture.rewrite("META-INF/container.xml") { $0.replacingOccurrences(of: "OEBPS/content.opf", with: "%2e%2e/outside.opf") }
        case "navTraversal":
            try fixture.rewrite("OEBPS/nav.xhtml") { $0.replacingOccurrences(of: "chapter1.xhtml", with: "../../outside.xhtml") }
        default:
            // From OEBPS/, one `..` is still the package root; two leave it.
            let unsafe = switch defect {
            case "encodedTraversal": "%2e%2e/%2e%2e/outside.xhtml"
            case "encodedSlashTraversal": "a%2fb/../../../outside.xhtml"
            default: "../../outside.xhtml"
            }
            if defect == "encodedSlashTraversal" { try fixture.write("OEBPS/a%2fb/placeholder.txt", text: "") }
            try fixture.rewrite("OEBPS/content.opf") { $0.replacingOccurrences(of: "chapter1.xhtml", with: unsafe) }
        }
        for mode in [EPUBParsingMode.strict, .lenient] {
            do {
                _ = try EPUBParser(mode: mode).parseEPUB(at: fixture.archive())
                Issue.record("Path safety should reject \(defect) in both modes.")
            } catch let VellumError.strictValidationFailed(diagnostics) {
                #expect(diagnostics.contains { $0.code == code })
            }
        }
    }
}

@Test(arguments: ["mimetype", "missingContainer", "malformedContainer", "missingOPF", "malformedOPF", "containerMediaType"])
func lenientModeStillRequiresReadablePackageDocuments(defect: String) throws {
    try withReadingFixture { fixture in
        let code: String
        switch defect {
        case "mimetype":
            code = "PAR001"
            try fixture.write("mimetype", text: "invalid")
        case "missingContainer":
            code = "PAR002"
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("META-INF/container.xml"))
        case "malformedContainer":
            code = "PAR006"
            try fixture.write("META-INF/container.xml", text: "<container><rootfiles>")
        case "missingOPF":
            code = "PAR003"
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("OEBPS/content.opf"))
        case "malformedOPF":
            code = "PAR007"
            try fixture.write("OEBPS/content.opf", text: "<package><metadata>")
        default:
            code = "PAR037"
            try fixture.rewrite("META-INF/container.xml") { $0.replacingOccurrences(of: "application/oebps-package+xml", with: "text/plain") }
        }
        for mode in [EPUBParsingMode.strict, .lenient] {
            do {
                _ = try EPUBParser(mode: mode).parseExtractedEPUB(at: fixture.root)
                Issue.record("Package integrity should reject \(defect) in both modes.")
            } catch let VellumError.strictValidationFailed(diagnostics) {
                #expect(diagnostics.contains { $0.code == code })
            }
        }
    }
}

@Test func olderBookAndTOCEncodingsDecodeWithDefaults() throws {
    let decoder = JSONDecoder()
    let node = try decoder.decode(EPUBTOCNode.self, from: Data(#"{"label":"One","href":"one.xhtml"}"#.utf8))
    #expect(node.level == 0)
    let book = EPUBBook(metadata: EPUBMetadata(identifier: "id", title: "Book", creator: "Author"), manifest: [], spine: [], toc: [node], chapters: [])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
    object.removeValue(forKey: "diagnostics")
    let oldBook = try decoder.decode(EPUBBook.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(oldBook.diagnostics.isEmpty)
    let warning = VellumDiagnostic(code: "PAR025", severity: .warning, specRule: "Resource", filePath: "font.otf", message: "Missing font", hint: "Include font")
    let newBook = EPUBBook(metadata: book.metadata, manifest: [], spine: [], toc: [.init(label: "Section", href: "one.xhtml#section", level: 2)], chapters: [], diagnostics: [warning])
    let roundTrip = try decoder.decode(EPUBBook.self, from: JSONEncoder().encode(newBook))
    #expect(roundTrip == newBook)
}

// MARK: - ZIP fixtures

private func navigationXML(_ items: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <body><nav epub:type="toc"><ol>\(items)</ol></nav></body>
    </html>
    """
}

private func encryptionXML(algorithm: String, uri: String) -> String {
    """
    <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
      <enc:EncryptedData><enc:EncryptionMethod Algorithm="\(algorithm)"/>
        <enc:CipherData><enc:CipherReference URI="\(uri)"/></enc:CipherData>
      </enc:EncryptedData>
    </encryption>
    """
}

// MARK: - App API regressions (vellum #1 review)

@Test("A manifest href repeated with a fragment is a duplicate, and opening never traps on it")
func fragmentAliasIsADuplicateHref() throws {
    try withReadingFixture { fixture in
        try fixture.rewrite("OEBPS/content.opf") {
            $0.replacingOccurrences(of: "</manifest>",
                                    with: #"<item id="alias" href="chapter1.xhtml#alias" media-type="application/xhtml+xml"/></manifest>"#)
        }
        let archive = try fixture.archive()
        do {
            _ = try EPUBPublicationService().open(url: archive)
            Issue.record("Opening should reject a second manifest entry for the same file")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.contains { $0.code == "PAR015" })
        }
        do {
            _ = try EPUBParser(mode: .lenient).parseEPUB(at: archive)
            Issue.record("Lenient parsing rejects duplicate hrefs too")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.contains { $0.code == "PAR015" })
        }
        // Resolving a book that does carry both entries keeps the first
        // instead of trapping on the duplicate key.
        let book = try EPUBParser().parseEPUB(at: try {
            try fixture.rewrite("OEBPS/content.opf") { $0.replacingOccurrences(of: #"<item id="alias" href="chapter1.xhtml#alias" media-type="application/xhtml+xml"/>"#, with: "") }
            return try fixture.archive()
        }())
        let alias = EPUBManifestItem(id: "alias", href: "chapter1.xhtml#alias", mediaType: "application/xhtml+xml")
        let duplicated = EPUBBook(metadata: book.metadata, manifest: book.manifest + [alias], spine: book.spine,
                                  toc: book.toc, chapters: book.chapters)
        let publication = PublicationResolver.resolve(duplicated)
        #expect(publication.resource(href: "chapter1.xhtml") != nil)
        #expect(publication.resource(href: "chapter1.xhtml")?.id != "alias")
    }
}

@Test("A UTF-16 chapter is still readable after the book is saved and reopened")
func utf16ChapterSurvivesSaving() throws {
    try withReadingFixture { fixture in
        let path = "OEBPS/chapter1.xhtml"
        let text = try String(contentsOf: fixture.root.appendingPathComponent(path), encoding: .utf8)
            .replacingOccurrences(of: "UTF-8", with: "UTF-16")
        try fixture.write(path, data: Data([0xFF, 0xFE]) + (try #require(text.data(using: .utf16LittleEndian))))
        let service = EPUBPublicationService()
        let editable = try service.openEditable(url: fixture.archive())
        #expect(!(editable.chapters.first?.xhtml.contains("UTF-16") ?? true), "The text says what it is now")
        let saved = fixture.directory.appendingPathComponent("saved.epub")
        try service.save(editable, to: saved)
        let reopened = try service.open(url: saved)
        #expect(reopened.publication.readingOrder.first?.plainText.contains("Lorem ipsum") == true)
    }
}

@Test("Percent-encoded hrefs reach their files through the app API, and editing keeps them")
func encodedHrefsResolveThroughResources() throws {
    try withReadingFixture { fixture in
        let cover = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try fixture.move("OEBPS/chapter1.xhtml", to: "OEBPS/Chapter 1.xhtml")
        try fixture.write("OEBPS/images/Cover One.jpg", data: cover)
        try fixture.rewrite("OEBPS/content.opf") {
            $0.replacingOccurrences(of: "chapter1.xhtml", with: "Chapter%201.xhtml")
                .replacingOccurrences(of: "</manifest>", with: #"<item id="cover-one" href="images/Cover%20One.jpg" media-type="image/jpeg" properties="cover-image"/></manifest>"#)
        }
        try fixture.write("OEBPS/nav.xhtml", text: navigationXML("""
        <li><a href="Chapter%201.xhtml">First</a></li>
        <li><a href="chapter2.xhtml">Second</a></li>
        """))
        let archive = try fixture.archive()
        let opened = try EPUBPublicationService().open(url: archive)
        #expect(try opened.resources.data(forHref: "Chapter%201.xhtml").isEmpty == false)
        #expect(try opened.resources.data(forHref: "images/Cover%20One.jpg") == cover)
        #expect(opened.resources.fileURL(forHref: "Chapter%201.xhtml#part")?.lastPathComponent == "Chapter 1.xhtml")
        #expect(opened.publication.coverResource?.href == "images/Cover%20One.jpg")
        let editable = try EPUBPublicationService().openEditable(url: archive)
        #expect(editable.assets.contains { $0.href == "images/Cover%20One.jpg" }, "The cover isn't dropped")
        // Saved files take the decoded names, so the book reopens; the
        // manifest keeps its spelling.
        let saved = fixture.directory.appendingPathComponent("saved.epub")
        try EPUBPublicationService().save(editable, to: saved)
        let reopened = try EPUBPublicationService().open(url: saved)
        #expect(try reopened.resources.data(forHref: "images/Cover%20One.jpg") == cover)
        #expect(reopened.publication.readingOrder.first?.href == "Chapter%201.xhtml")
        #expect(reopened.publication.readingOrder.first?.plainText.contains("Lorem ipsum") == true)
    }
}

@Test("A package document in a percent-encoded folder opens, edits and saves through the app API")
func encodedPackageFolderWorksThroughTheService() throws {
    try withReadingFixture { fixture in
        let oebps = fixture.root.appendingPathComponent("OEBPS")
        let folder = oebps.appendingPathComponent("My Book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: oebps.path) where name != "My Book" {
            try FileManager.default.moveItem(at: oebps.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        try fixture.rewrite("META-INF/container.xml") {
            $0.replacingOccurrences(of: "OEBPS/content.opf", with: "OEBPS/My%20Book/content.opf")
        }
        let archive = try fixture.archive()
        let service = EPUBPublicationService()
        let opened = try service.open(url: archive)
        #expect(opened.publication.readingOrder.count == 2)
        #expect(try opened.resources.data(forHref: "chapter1.xhtml").isEmpty == false)
        let editable = try service.openEditable(url: archive)
        #expect(editable.chapters.count == 2)
        let saved = fixture.directory.appendingPathComponent("saved.epub")
        try service.save(editable, to: saved)
        #expect(try service.open(url: saved).publication.readingOrder.count == 2)
    }
}

@Test("An undecodable chapter becomes a warning and a placeholder in lenient mode, not a failed book")
func undecodableChapterIsAPlaceholderInLenientMode() throws {
    try withReadingFixture { fixture in
        // Invalid UTF-8, with nothing that reads as UTF-16 or a declaration.
        try fixture.write("OEBPS/chapter2.xhtml", data: Data([0x3C, 0x68, 0xC3, 0x28, 0xFF, 0x3E]))
        let archive = try fixture.archive()
        #expect(throws: VellumError.self) { try EPUBParser().parseEPUB(at: archive) }
        let book = try EPUBParser(mode: .lenient).parseEPUB(at: archive)
        #expect(book.diagnostics.contains { $0.code == "PAR045" && $0.severity == .warning })
        #expect(book.chapters.count == 2)
        #expect(book.chapters[0].plainText.contains("Lorem ipsum"))
        #expect(book.chapters[1].xhtml.isEmpty)
    }
}

@Test("A truncated package document is malformed on every platform")
func truncatedPackageDocumentIsMalformed() throws {
    try withReadingFixture { fixture in
        try fixture.write("OEBPS/content.opf", text: #"<?xml version="1.0" encoding="UTF-8"?><package version="3.0"><metadata>"#)
        do {
            _ = try EPUBParser(mode: .lenient).parseExtractedEPUB(at: fixture.root)
            Issue.record("A truncated OPF must not parse")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.map(\.code) == ["PAR007"])
        }
    }
}

@Test("An encoded href naming an existing file is a duplicate: editing rejects it and nothing is overwritten")
func encodedAliasCantOverwriteAChapterOnSave() throws {
    try withReadingFixture { fixture in
        let service = EPUBPublicationService()
        let editable = try service.openEditable(url: fixture.archive())
        let chapterHref = try #require(editable.chapters.first?.href)
        #expect(chapterHref == "chapter1.xhtml")
        let alias = EditableAsset(id: "alias", href: "chapter%31.xhtml", mediaType: "application/xhtml+xml", data: Data("<html/>".utf8))
        do {
            _ = try EPUBPublicationEditor().apply(.addAsset(alias), to: editable)
            Issue.record("An asset naming chapter1.xhtml's file must be rejected")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.contains { $0.code == "EDT007" })
        }
        // Saving a publication that already carries both is refused too,
        // before anything is written.
        let both = EditablePublication(metadata: editable.metadata, chapters: editable.chapters,
                                       assets: editable.assets + [alias], includeLegacyNCX: editable.includeLegacyNCX)
        let saved = fixture.directory.appendingPathComponent("saved.epub")
        #expect(throws: VellumError.self) { try service.save(both, to: saved) }
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }
}

@Test("A chapter or asset can't take a file the package generates itself")
func generatedFileNamesAreReserved() throws {
    try withReadingFixture { fixture in
        let service = EPUBPublicationService()
        let editable = try service.openEditable(url: fixture.archive())
        // A chapter whose name decodes to the generated navigation document.
        var chapters = editable.chapters
        let first = chapters[0]
        chapters[0] = EditableChapter(id: first.id, href: "n%61v.xhtml", title: first.title, xhtml: first.xhtml)
        let renamed = EditablePublication(metadata: editable.metadata, chapters: chapters, assets: editable.assets,
                                          includeLegacyNCX: editable.includeLegacyNCX)
        let saved = fixture.directory.appendingPathComponent("saved.epub")
        do {
            try service.save(renamed, to: saved)
            Issue.record("Saving must not overwrite the chapter with the generated nav.xhtml")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.contains { $0.code == "EDT010" })
        }
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        // An encoded escape to the package's own mimetype.
        let sneaky = EditableAsset(id: "sneaky", href: "%2e%2e/mimetype", mediaType: "text/plain", data: Data("x".utf8))
        do {
            _ = try EPUBPublicationEditor().apply(.addAsset(sneaky), to: editable)
            Issue.record("An asset must not replace the package's mimetype")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.contains { $0.code == "EDT005" })
            #expect(diagnostics.contains { $0.code == "EDT010" })
        }
    }
}

@Test("Created books round-trip file names with spaces and percent signs", arguments: ["Chapter%201.xhtml", "literal%25.xhtml", "Chapter 1.xhtml"])
func createdFileNamesRoundTrip(fileName: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-create-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cover = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let request = CreateRequest(
        metadata: EPUBMetadata(identifier: "urn:uuid:create-roundtrip", title: "Round Trip", creator: "Tester"),
        chapters: [EPUBChapterInput(id: "one", title: "One", markdown: "The first chapter.", fileName: fileName),
                   EPUBChapterInput(id: "two", title: "Two", markdown: "The second chapter.", fileName: "chapter2.xhtml")],
        assets: [EPUBAsset(id: "cover", relativePath: "images/Cover One.jpg", mediaType: "image/jpeg", data: cover, properties: ["cover-image"])]
    )
    let output = directory.appendingPathComponent("created.epub")
    try EPUBCreator().createEPUB(request, outputURL: output)
    let book = try EPUBParser().parseEPUB(at: output)
    #expect(book.chapters.map(\.plainText).first?.contains("The first chapter.") == true)
    let opened = try EPUBPublicationService().open(url: output)
    #expect(opened.resources.fileURL(forHref: book.chapters[0].href)?.lastPathComponent == fileName)
    #expect(try opened.resources.data(forHref: "images/Cover%20One.jpg") == cover)
}

@Test("Names Apple's file systems treat as one file can't overwrite each other, or leave the package, on save")
func fileSystemAliasesAreRejectedOnSave() throws {
    try withReadingFixture { fixture in
        let service = EPUBPublicationService()
        let editable = try service.openEditable(url: fixture.archive())
        let alias = EditableAsset(id: "alias", href: "CHAPTER%31.xhtml", mediaType: "application/xhtml+xml", data: Data("<html/>".utf8))
        do {
            _ = try EPUBPublicationEditor().apply(.addAsset(alias), to: editable)
            Issue.record("CHAPTER1.xhtml is chapter1.xhtml on a case-insensitive file system")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.contains { $0.code == "EDT007" })
        }
        let first = editable.chapters[0]
        for (href, code) in [("n%61V.xhtml", "EDT010"), ("%2e%2e/outside.xhtml", "EDT005")] {
            var chapters = editable.chapters
            chapters[0] = EditableChapter(id: first.id, href: href, title: first.title, xhtml: first.xhtml)
            let renamed = EditablePublication(metadata: editable.metadata, chapters: chapters, assets: editable.assets,
                                              includeLegacyNCX: editable.includeLegacyNCX)
            let saved = fixture.directory.appendingPathComponent("saved-\(UUID().uuidString).epub")
            do {
                try service.save(renamed, to: saved)
                Issue.record("Saving a chapter at \(href) must be refused")
            } catch let VellumError.strictValidationFailed(diagnostics) {
                #expect(diagnostics.contains { $0.code == code }, "\(href)")
            }
            #expect(!FileManager.default.fileExists(atPath: saved.path))
        }
    }
}

@Test("A manifest file whose name starts with a dot survives saving and reopening")
func dotfileChapterSurvivesSaving() throws {
    try withReadingFixture { fixture in
        try fixture.move("OEBPS/chapter1.xhtml", to: "OEBPS/.chapter1.xhtml")
        try fixture.rewrite("OEBPS/content.opf") { $0.replacingOccurrences(of: "chapter1.xhtml", with: "%2Echapter1.xhtml") }
        try fixture.write("OEBPS/nav.xhtml", text: navigationXML("""
        <li><a href="%2Echapter1.xhtml">First</a></li>
        <li><a href="chapter2.xhtml">Second</a></li>
        """))
        let service = EPUBPublicationService()
        let editable = try service.openEditable(url: fixture.archive())
        let saved = fixture.directory.appendingPathComponent("saved.epub")
        try service.save(editable, to: saved)
        let reopened = try service.open(url: saved)
        #expect(reopened.publication.readingOrder.first?.plainText.contains("Lorem ipsum") == true)
        #expect(reopened.resources.fileURL(forHref: "%2Echapter1.xhtml")?.lastPathComponent == ".chapter1.xhtml")
    }
}

@Test("A Unicode case alias (straße for strasse) never silently replaces a chapter on save")
func unicodeCaseAliasNeverReplacesAChapter() throws {
    try withReadingFixture { fixture in
        try fixture.move("OEBPS/chapter1.xhtml", to: "OEBPS/strasse.xhtml")
        try fixture.rewrite("OEBPS/content.opf") { $0.replacingOccurrences(of: "chapter1.xhtml", with: "strasse.xhtml") }
        try fixture.write("OEBPS/nav.xhtml", text: navigationXML("""
        <li><a href="strasse.xhtml">First</a></li>
        <li><a href="chapter2.xhtml">Second</a></li>
        """))
        let service = EPUBPublicationService()
        let editable = try service.openEditable(url: fixture.archive())
        let alias = EditableAsset(id: "alias", href: "stra%C3%9Fe.xhtml", mediaType: "application/xhtml+xml",
                                  data: Data("<html><body><p>replacement</p></body></html>".utf8))
        do {
            _ = try EPUBPublicationEditor().apply(.addAsset(alias), to: editable)
            Issue.record("straße.xhtml is strasse.xhtml on Apple's file systems")
        } catch let VellumError.strictValidationFailed(diagnostics) {
            #expect(diagnostics.contains { $0.code == "EDT007" })
        }
        // A publication already carrying both: saving refuses, or (on a file
        // system where they're different files) keeps the chapter. Never a swap.
        let both = EditablePublication(metadata: editable.metadata, chapters: editable.chapters,
                                       assets: editable.assets + [alias], includeLegacyNCX: editable.includeLegacyNCX)
        let saved = fixture.directory.appendingPathComponent("saved.epub")
        if (try? service.save(both, to: saved)) != nil {
            let reopened = try service.open(url: saved)
            #expect(reopened.publication.readingOrder.first?.plainText.contains("Lorem ipsum") == true)
        } else {
            #expect(!FileManager.default.fileExists(atPath: saved.path))
        }
    }
}

private func withReadingFixture(_ body: (ReadingFixture) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-reading-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.epub")
    try EPUBCreator().createEPUB(SampleBookFactory.makeReaderSafeLoremIpsumBook(chapterCount: 2), outputURL: source)
    let root = directory.appendingPathComponent("extracted")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runReadingFixtureCommand("/usr/bin/unzip", ["-q", source.path, "-d", root.path])
    try body(ReadingFixture(directory: directory, root: root))
}

private struct ReadingFixture {
    let directory: URL
    let root: URL

    func write(_ path: String, text: String) throws { try write(path, data: Data(text.utf8)) }

    func write(_ path: String, data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func rewrite(_ path: String, transform: (String) -> String) throws {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        try write(path, text: transform(text))
    }

    func move(_ path: String, to destination: String) throws {
        let target = root.appendingPathComponent(destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(path), to: target)
    }

    func removeNav(useEPUB2: Bool = false) throws {
        try rewrite("OEBPS/content.opf") {
            let withoutNav = $0.replacingOccurrences(of: #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#, with: "")
            return useEPUB2 ? withoutNav.replacingOccurrences(of: #"version="3.0""#, with: #"version="2.0""#) : withoutNav
        }
    }

    /// `including` adds folders at the archive root besides META-INF and OEBPS.
    func archive(including extraFolders: [String] = []) throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).epub")
        try runReadingFixtureCommand("/usr/bin/zip", ["-X0q", url.path, "mimetype"], cwd: root)
        try runReadingFixtureCommand("/usr/bin/zip", ["-Xr9q", url.path, "META-INF", "OEBPS"] + extraFolders, cwd: root)
        return url
    }
}

private func runReadingFixtureCommand(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw VellumError.ioFailure("Fixture command failed: \(executable)") }
}
