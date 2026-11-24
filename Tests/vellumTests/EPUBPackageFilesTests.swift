import Foundation
import Testing

@testable import vellum

private func writePackage(opfPath: String, files: [(String, Data)]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-package-files-\(UUID().uuidString).epub")
    let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """
    var entries: [ZipArchiveWriter.Entry] = [
        .init(path: "mimetype", data: Data("application/epub+zip".utf8), compressionMethod: .store),
        .init(path: "META-INF/container.xml", data: Data(container.utf8), compressionMethod: .deflate),
        .init(path: opfPath, data: Data("<package/>".utf8), compressionMethod: .deflate),
    ]
    entries += files.map { .init(path: $0.0, data: $0.1, compressionMethod: .deflate) }
    try ZipArchiveWriter.write(entries: entries, to: url)
    return url
}

@Test func packageFilesReadAnImageRelativeToThePackageDocument() throws {
    let image = Data((0..<4096).map { UInt8($0 % 251) })
    let url = try writePackage(opfPath: "OEBPS/content.opf", files: [("OEBPS/images/map 1.jpg", image)])
    defer { try? FileManager.default.removeItem(at: url) }

    let files = try EPUBPackageFiles(url: url)
    #expect(files.opfDirectory == "OEBPS")
    #expect(try files.data(atManifestPath: "images/map 1.jpg") == image)
    // Hrefs arrive percent-encoded and with fragments.
    #expect(try files.data(atManifestPath: "images/map%201.jpg#view") == image)
    #expect(try files.data(atManifestPath: "text/../images/map%201.jpg") == image)
    #expect(try files.data(atManifestPath: "images/missing.jpg") == nil)
}

@Test func packageFilesReadFromAPackageDocumentAtTheRoot() throws {
    let image = Data("png".utf8)
    let url = try writePackage(opfPath: "content.opf", files: [("art/orn.png", image)])
    defer { try? FileManager.default.removeItem(at: url) }

    let files = try EPUBPackageFiles(url: url)
    #expect(files.opfDirectory == "")
    #expect(try files.data(atManifestPath: "art/orn.png") == image)
}

@Test func packageFilesNeverLeaveTheArchive() throws {
    let url = try writePackage(opfPath: "OEBPS/content.opf", files: [("secret.txt", Data("x".utf8))])
    defer { try? FileManager.default.removeItem(at: url) }

    let files = try EPUBPackageFiles(url: url)
    // Up to the archive root is still inside it; past the root is not.
    #expect(try files.data(atManifestPath: "../secret.txt") == Data("x".utf8))
    #expect(files.archivePath(forManifestPath: "../../secret.txt") == nil)
    #expect(files.archivePath(forManifestPath: "/etc/passwd") == nil)
    #expect(files.archivePath(forManifestPath: "https://example.com/a.png") == nil)
    #expect(files.archivePath(forManifestPath: "") == nil)
}

@Test func packageFilesOpenWhileAnotherXMLParserIsRunning() throws {
    let image = Data("pixels".utf8)
    let url = try writePackage(opfPath: "OEBPS/content.opf", files: [("OEBPS/images/a.png", image)])
    defer { try? FileManager.default.removeItem(at: url) }

    final class Opener: NSObject, XMLParserDelegate {
        let url: URL
        var read: Data?
        init(url: URL) { self.url = url }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard elementName == "img" else { return }
            read = try? EPUBPackageFiles(url: url).data(atManifestPath: "images/a.png")
        }
    }
    let opener = Opener(url: url)
    let parser = XMLParser(data: Data(#"<html><body><img src="images/a.png"/></body></html>"#.utf8))
    parser.delegate = opener
    #expect(parser.parse())
    #expect(opener.read == image)
}

@Test func rootfilePathSkipsCommentsAndReadsUTF16() throws {
    let commented = #"<container><!-- <rootfile full-path="old/content.opf"/> --><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#
    #expect(try EPUBPackageFiles.rootfilePath(in: Data(commented.utf8)) == "OEBPS/content.opf")
    let utf16 = #"<?xml version="1.0" encoding="UTF-16"?><container><rootfiles><rootfile full-path="EPUB/package.opf"/></rootfiles></container>"#
    let data = try #require(utf16.data(using: .utf16))  // with a byte-order mark
    #expect(try EPUBPackageFiles.rootfilePath(in: data) == "EPUB/package.opf")
}

@Test func packageFilesReadDecodedPathsOnce() throws {
    let image = Data("hash".utf8)
    let url = try writePackage(opfPath: "OEBPS/content.opf", files: [("OEBPS/images/map #1 100%.jpg", image)])
    defer { try? FileManager.default.removeItem(at: url) }
    let files = try EPUBPackageFiles(url: url)
    #expect(try files.data(atPackagePath: "images/map #1 100%.jpg") == image)
    #expect(try files.data(atManifestPath: "images/map%20%231%20100%25.jpg") == image)
    #expect(files.archivePath(forPackagePath: "../../x") == nil)
}

@Test func rootfilePathReadsPrefixedAndSingleQuotedContainers() throws {
    let prefixed = #"<c:container xmlns:c="urn:oasis:names:tc:opendocument:xmlns:container"><c:rootfiles><c:rootfile media-type="application/oebps-package+xml" full-path='EPUB/pkg&amp;1.opf'/></c:rootfiles></c:container>"#
    #expect(try EPUBPackageFiles.rootfilePath(in: Data(prefixed.utf8)) == "EPUB/pkg&1.opf")
    #expect(throws: (any Error).self) { try EPUBPackageFiles.rootfilePath(in: Data("<container/>".utf8)) }
}
