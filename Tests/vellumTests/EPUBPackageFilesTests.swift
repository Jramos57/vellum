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

@Test func packageFilesUseTheParsersRendition() throws {
    // Two renditions and a commented-out one: the parser reads the last real
    // rootfile, and so do the package files.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-renditions-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: url) }
    let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <!-- <rootfile full-path="old/content.opf" media-type="application/oebps-package+xml"/> -->
      <rootfiles>
        <rootfile full-path="a/one.opf" media-type="application/oebps-package+xml"/>
        <rootfile full-path="b/tw&#111;.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
    try ZipArchiveWriter.write(entries: [
        .init(path: "mimetype", data: Data("application/epub+zip".utf8), compressionMethod: .store),
        .init(path: "META-INF/container.xml", data: Data(container.utf8), compressionMethod: .deflate),
        .init(path: "b/images/x.png", data: Data("b".utf8), compressionMethod: .deflate),
        .init(path: "a/images/x.png", data: Data("a".utf8), compressionMethod: .deflate),
    ], to: url)
    let files = try EPUBPackageFiles(url: url)
    #expect(files.opfDirectory == "b")
    #expect(try files.data(atManifestPath: "images/x.png") == Data("b".utf8))
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
