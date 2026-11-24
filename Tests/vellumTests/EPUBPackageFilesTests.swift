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

@Test func packageFilesRejectEveryEscapingSpelling() throws {
    let url = try writePackage(opfPath: "OEBPS/content.opf", files: [("OEBPS/images/a.png", Data("a".utf8)), ("...png", Data("dots".utf8))])
    defer { try? FileManager.default.removeItem(at: url) }
    let files = try EPUBPackageFiles(url: url)
    // An escaped absolute path, scheme or NUL, even behind a fragment with a bare %.
    #expect(files.archivePath(forManifestPath: "%2Fsecret.txt#100%") == nil)
    #expect(files.archivePath(forManifestPath: "https%3A//example.com/a.png#100%") == nil)
    #expect(files.archivePath(forManifestPath: "images/a%00b.png#100%") == nil)
    // Escapes when read as spelled though not when decoded (and the reverse).
    #expect(files.archivePath(forManifestPath: "a%2fb/../../../secret.txt") == nil)
    // A root file whose name starts with dots is still inside.
    #expect(try files.data(atManifestPath: "../...png") == Data("dots".utf8))
    // The package directory itself isn't a file.
    #expect(files.archivePath(forPackagePath: ".") == nil)
    #expect(files.archivePath(forPackagePath: "images/..") == nil)
    // A fragment never changes the file.
    #expect(try files.data(atManifestPath: "images/a.png#frag%") == Data("a".utf8))
}

@Test func packageFilesRefuseAnUnsafeRootfile() throws {
    for unsafe in ["../content.opf", "%2e%2e/content.opf", "/OEBPS/content.opf", "%2e%2e/content.opf#100%",
                   "%2FOEBPS/content.opf#100%", "./..", "OEBPS/.."] {
        // A safe archive whose container names an unsafe package path.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-unsafe-rootfile-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: url) }
        let container = #"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="\#(unsafe)" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        try ZipArchiveWriter.write(entries: [
            .init(path: "mimetype", data: Data("application/epub+zip".utf8), compressionMethod: .store),
            .init(path: "META-INF/container.xml", data: Data(container.utf8), compressionMethod: .deflate),
            .init(path: "content.opf", data: Data("<package/>".utf8), compressionMethod: .deflate),
        ], to: url)
        #expect(throws: VellumError.self) { _ = try EPUBPackageFiles(url: url) }
    }
}
