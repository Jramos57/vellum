import Foundation
import ZIPFoundation

enum Internal {
    static let oebps = "OEBPS"
    static let containerPath = "META-INF/container.xml"
    static let opfPath = "OEBPS/content.opf"
    static let navPath = "OEBPS/nav.xhtml"
    static let tocNCXPath = "OEBPS/toc.ncx"
    static let cssPath = "OEBPS/styles/main.css"
    static let scriptPath = "OEBPS/scripts/app.js"
    static let imagePath = "OEBPS/images/cover.jpg"
    static let svgPath = "OEBPS/images/diagram.svg"
    static let fontPath = "OEBPS/fonts/demo.otf"
    static let audioPath = "OEBPS/audio/sample.mp3"
    static let videoPath = "OEBPS/video/sample.mp4"
}

enum ZipTool {
    static func makeArchive(from directory: URL, output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let archive: Archive
        do {
            archive = try Archive(url: output, accessMode: .create)
        } catch {
            throw VellumError.ioFailure("Failed to create archive at \(output.path): \(error.localizedDescription)")
        }

        try addMimetypeEntry(to: archive)
        try addContentEntries(to: archive, relativeTo: directory)
    }

    static func extractArchive(_ archiveURL: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw VellumError.ioFailure("Failed to open archive at \(archiveURL.path): \(error.localizedDescription)")
        }

        for entry in archive {
            let outputURL = directory.appending(path: entry.path)
            let parentURL = outputURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

            if entry.type == .directory {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                continue
            }

            do {
                _ = try archive.extract(entry, to: outputURL)
            } catch {
                throw VellumError.ioFailure("Failed to extract \(entry.path): \(error.localizedDescription)")
            }
        }
    }

    static func validateMimetypeConstraints(archiveURL: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw VellumError.ioFailure("Failed to open archive at \(archiveURL.path): \(error.localizedDescription)")
        }
        let entries = Array(archive)
        var diagnostics: [VellumDiagnostic] = []
        if entries.first?.path != "mimetype" {
            diagnostics.append(
                .init(
                    code: "ZIP001",
                    specRule: "EPUB 3.3 OCF ZIP Container",
                    filePath: "mimetype",
                    message: "mimetype is not the first ZIP entry.",
                    hint: "Ensure mimetype is added first during archive creation."
                )
            )
        }

        if let mimetypeEntry = entries.first(where: { $0.path == "mimetype" }),
           mimetypeEntry.isCompressed {
            diagnostics.append(
                .init(
                    code: "ZIP002",
                    specRule: "EPUB 3.3 OCF ZIP Container",
                    filePath: "mimetype",
                    message: "mimetype entry is compressed.",
                    hint: "Write mimetype with storage mode 0 (uncompressed)."
                )
            )
        }

        if !diagnostics.isEmpty {
            throw VellumError.strictValidationFailed(diagnostics)
        }
    }

    private static func addMimetypeEntry(to archive: Archive) throws {
        let mimetypeData = Data("application/epub+zip".utf8)
        let dataCount = mimetypeData.count

        try archive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: Int64(dataCount),
            compressionMethod: .none
        ) { position, size in
            let start = Int(position)
            guard start < dataCount else { return Data() }
            let end = min(start + size, dataCount)
            return mimetypeData.subdata(in: start..<end)
        }
    }

    private static func addContentEntries(to archive: Archive, relativeTo rootDirectory: URL) throws {
        let fileManager = FileManager.default
        let resolvedRootPath = rootDirectory.resolvingSymlinksInPath().path
        let directoryPrefix = resolvedRootPath.hasSuffix("/")
            ? resolvedRootPath
            : resolvedRootPath + "/"

        for component in ["META-INF", "OEBPS"] {
            let componentURL = rootDirectory.appendingPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: componentURL.path) else { continue }

            guard let enumerator = fileManager.enumerator(
                at: componentURL,
                includingPropertiesForKeys: [URLResourceKey.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [URLResourceKey.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let resolvedFilePath = fileURL.resolvingSymlinksInPath().path
                guard resolvedFilePath.hasPrefix(directoryPrefix) else {
                    throw VellumError.ioFailure("Failed to resolve archive-relative path for \(fileURL.path).")
                }

                let relativePath = String(resolvedFilePath.dropFirst(directoryPrefix.count))
                try archive.addEntry(
                    with: relativePath,
                    relativeTo: rootDirectory,
                    compressionMethod: .deflate
                )
            }
        }
    }
}

extension String {
    func xmlEscaped() -> String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
