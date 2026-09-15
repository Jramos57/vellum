import Foundation

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

        do {
            var entries: [ZipArchiveWriter.Entry] = []
            addMimetypeEntry(to: &entries)
            try addContentEntries(to: &entries, relativeTo: directory)
            try ZipArchiveWriter.write(entries: entries, to: output)
        } catch let error as ZipArchiveError {
            throw VellumError.ioFailure("Failed to create archive at \(output.path): \(error.localizedDescription)")
        } catch {
            throw VellumError.ioFailure("Failed to create archive at \(output.path): \(error.localizedDescription)")
        }
    }

    static func extractArchive(_ archiveURL: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let archive: ZipArchiveReader
        do {
            archive = try ZipArchiveReader(url: archiveURL)
        } catch {
            throw VellumError.ioFailure("Failed to open archive at \(archiveURL.path): \(error.localizedDescription)")
        }

        for entry in archive.entries {
            do {
                let safePath = try safeExtractionPath(for: entry.path)
                let outputURL = try resolvedDestinationURL(for: safePath, rootDirectory: directory)
                let parentURL = outputURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

                if entry.isDirectory {
                    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    continue
                }

                let extractedData = try archive.data(for: entry)
                try extractedData.write(to: outputURL)
            } catch {
                throw VellumError.ioFailure("Failed to extract \(entry.path): \(error.localizedDescription)")
            }
        }
    }

    static func validateMimetypeConstraints(archiveURL: URL) throws {
        let archive: ZipArchiveReader
        do {
            archive = try ZipArchiveReader(url: archiveURL)
        } catch {
            throw VellumError.ioFailure("Failed to open archive at \(archiveURL.path): \(error.localizedDescription)")
        }

        let entries = archive.entries
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
           mimetypeEntry.compressionMethod != .store {
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

    private static func addMimetypeEntry(to entries: inout [ZipArchiveWriter.Entry]) {
        let mimetypeData = Data("application/epub+zip".utf8)
        entries.append(
            .init(path: "mimetype", data: mimetypeData, compressionMethod: .store)
        )
    }

    private static func addContentEntries(to entries: inout [ZipArchiveWriter.Entry], relativeTo rootDirectory: URL) throws {
        let fileManager = FileManager.default
        let resolvedRootPath = rootDirectory.resolvingSymlinksInPath().path
        let directoryPrefix = resolvedRootPath.hasSuffix("/")
            ? resolvedRootPath
            : resolvedRootPath + "/"
        var fileEntries: [(path: String, url: URL)] = []

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
                    .replacingOccurrences(of: "\\", with: "/")
                fileEntries.append((relativePath, fileURL))
            }
        }

        for fileEntry in fileEntries.sorted(by: { $0.path < $1.path }) {
            let data = try Data(contentsOf: fileEntry.url)
            entries.append(
                .init(path: fileEntry.path, data: data, compressionMethod: .deflate)
            )
        }
    }

    private static func safeExtractionPath(for rawPath: String) throws -> String {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else {
            throw ZipArchiveError.invalidArchive("ZIP entry has an empty path.")
        }
        guard !normalized.hasPrefix("/") else {
            throw ZipArchiveError.invalidArchive("ZIP entry path is absolute and unsafe.")
        }

        if normalized.count >= 2 {
            let first = normalized[normalized.startIndex]
            let second = normalized[normalized.index(after: normalized.startIndex)]
            if first.isASCIIAlpha, second == ":" {
                throw ZipArchiveError.invalidArchive("ZIP entry path contains a drive-letter prefix and is unsafe.")
            }
        }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        var sanitized: [String] = []
        sanitized.reserveCapacity(components.count)

        for component in components {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                throw ZipArchiveError.invalidArchive("ZIP entry path contains traversal segments and is unsafe.")
            }
            sanitized.append(String(component))
        }

        guard !sanitized.isEmpty else {
            throw ZipArchiveError.invalidArchive("ZIP entry path resolves to an empty destination.")
        }

        var safePath = sanitized.joined(separator: "/")
        if normalized.hasSuffix("/") {
            safePath.append("/")
        }
        return safePath
    }

    private static func resolvedDestinationURL(for relativePath: String, rootDirectory: URL) throws -> URL {
        let resolvedRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let destination = resolvedRoot.appendingPathComponent(relativePath).standardizedFileURL

        let rootPath = resolvedRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard destination.path == rootPath || destination.path.hasPrefix(rootPrefix) else {
            throw ZipArchiveError.invalidArchive("ZIP entry escapes extraction root.")
        }

        return destination
    }
}

private extension Character {
    var isASCIIAlpha: Bool {
        guard let asciiValue else { return false }
        return (asciiValue >= 65 && asciiValue <= 90) || (asciiValue >= 97 && asciiValue <= 122)
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
