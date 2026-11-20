import Foundation

/// A JSON description of an EPUB to build, whose chapter and asset contents
/// are read from files. `vellum-cli create <manifest.json> <output.epub>`
/// builds from one, so a book prepared by any tool (a script that splits or
/// reorders an existing EPUB, for example) can be packaged by vellum without
/// losing its own markup.
///
/// Relative file paths resolve against the manifest's folder.
///
/// ```json
/// {
///   "metadata": { "identifier": "urn:uuid:…", "title": "…", "creator": "…",
///                 "language": "en-US", "subjects": ["…"] },
///   "chapters": [
///     { "id": "c1", "title": "Genesis 1", "fileName": "c1.xhtml", "xhtmlFile": "text/c1.xhtml" },
///     { "id": "notes", "title": "Notes", "fileName": "notes.xhtml", "xhtmlFile": "text/notes.xhtml",
///       "linear": false, "includeInNavigation": false }
///   ],
///   "assets": [
///     { "id": "css", "relativePath": "book.css", "mediaType": "text/css", "file": "book.css" },
///     { "id": "cover", "relativePath": "images/cover.jpg", "mediaType": "image/jpeg",
///       "file": "images/cover.jpg", "properties": ["cover-image"] }
///   ],
///   "landmarks": [ { "type": "bodymatter", "title": "Start", "href": "c1.xhtml" } ],
///   "includeGeneratedPageList": false
/// }
/// ```
public struct EPUBBuildManifest: Codable, Sendable {
    /// Publication metadata.
    public struct Metadata: Codable, Sendable {
        public let identifier: String
        public let title: String
        public let creator: String
        public let language: String?
        /// ISO 8601 timestamp; the build time when omitted.
        public let modified: String?
        public let publisher: String?
        public let description: String?
        public let rights: String?
        public let subjects: [String]?
        public let source: String?
    }

    /// A chapter whose content is one XHTML or Markdown file.
    public struct Chapter: Codable, Sendable {
        public let id: String
        public let title: String
        /// File name inside the package.
        public let fileName: String
        /// An XHTML document packaged verbatim.
        public let xhtmlFile: String?
        /// A Markdown file converted with vellum's template.
        public let markdownFile: String?
        public let linear: Bool?
        public let includeInNavigation: Bool?
        public let properties: [String]?
    }

    /// A stylesheet, image, font or other resource copied into the package.
    public struct Asset: Codable, Sendable {
        public let id: String
        /// Path inside the package.
        public let relativePath: String
        public let mediaType: String
        /// File holding the asset's bytes.
        public let file: String
        public let properties: [String]?
    }

    public let metadata: Metadata
    public let chapters: [Chapter]
    public let assets: [Asset]?
    public let landmarks: [EPUBLandmark]?
    public let includeLegacyNCX: Bool?
    public let includeGeneratedPageList: Bool?

    /// Reads a manifest from a JSON file.
    ///
    /// - Parameter url: The manifest file.
    /// - Throws: ``VellumError`` when the file can't be read or decoded.
    public static func load(from url: URL) throws -> EPUBBuildManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VellumError.ioFailure("Unable to read build manifest \(url.path): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(EPUBBuildManifest.self, from: data)
        } catch {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "MAN001",
                    specRule: "vellum build manifest",
                    filePath: url.lastPathComponent,
                    message: "Build manifest isn't valid: \(Self.describe(error)).",
                    hint: "See EPUBBuildManifest for the expected JSON shape."
                )
            ])
        }
    }

    /// Reads every referenced file and returns the request ``EPUBCreator`` builds.
    ///
    /// - Parameter baseURL: Folder that relative file paths resolve against.
    /// - Throws: ``VellumError`` when a file is missing or a chapter names no content.
    public func makeRequest(relativeTo baseURL: URL) throws -> CreateRequest {
        var diagnostics: [VellumDiagnostic] = []
        var modified = Date()
        if let stamp = metadata.modified {
            if let date = ISO8601DateFormatter().date(from: stamp) {
                modified = date
            } else {
                diagnostics.append(.init(code: "MAN002", specRule: "vellum build manifest",
                                         message: "metadata.modified isn't an ISO 8601 timestamp: \(stamp).",
                                         hint: "Use a timestamp such as 2026-11-19T20:00:00Z, or omit it."))
            }
        }
        for chapter in chapters where (chapter.xhtmlFile == nil) == (chapter.markdownFile == nil) {
            diagnostics.append(.init(code: "MAN003", specRule: "vellum build manifest", filePath: chapter.fileName,
                                     message: "Chapter \(chapter.id) must name exactly one of xhtmlFile and markdownFile.",
                                     hint: "Give each chapter one content file."))
        }
        if !diagnostics.isEmpty { throw VellumError.strictValidationFailed(diagnostics) }

        let builtChapters = try chapters.map { chapter -> EPUBChapterInput in
            if let path = chapter.xhtmlFile {
                return EPUBChapterInput(
                    id: chapter.id, title: chapter.title,
                    xhtml: try EPUBDocumentText.read(at: Self.resolve(path, against: baseURL)),
                    fileName: chapter.fileName,
                    linear: chapter.linear ?? true,
                    includeInNavigation: chapter.includeInNavigation ?? true,
                    properties: chapter.properties ?? []
                )
            }
            let url = Self.resolve(chapter.markdownFile ?? "", against: baseURL)
            let markdown: String
            do {
                markdown = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw VellumError.ioFailure("Unable to read \(url.path): \(error.localizedDescription)")
            }
            return EPUBChapterInput(id: chapter.id, title: chapter.title, markdown: markdown, fileName: chapter.fileName,
                                    linear: chapter.linear ?? true, includeInNavigation: chapter.includeInNavigation ?? true,
                                    properties: chapter.properties ?? [])
        }
        let builtAssets = try (assets ?? []).map { asset -> EPUBAsset in
            let url = Self.resolve(asset.file, against: baseURL)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw VellumError.ioFailure("Unable to read \(url.path): \(error.localizedDescription)")
            }
            return EPUBAsset(id: asset.id, relativePath: asset.relativePath, mediaType: asset.mediaType,
                             data: data, properties: asset.properties ?? [])
        }
        return CreateRequest(
            metadata: EPUBMetadata(
                identifier: metadata.identifier,
                title: metadata.title,
                creator: metadata.creator,
                language: metadata.language ?? "en",
                modified: modified,
                publisher: metadata.publisher,
                description: metadata.description,
                rights: metadata.rights,
                subjects: metadata.subjects ?? [],
                source: metadata.source
            ),
            chapters: builtChapters,
            assets: builtAssets,
            includeLegacyNCX: includeLegacyNCX ?? true,
            landmarks: landmarks,
            includeGeneratedPageList: includeGeneratedPageList ?? true
        )
    }

    private static func resolve(_ path: String, against baseURL: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseURL.appendingPathComponent(path)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "missing \(Self.path(context.codingPath + [key]))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "wrong type at \(Self.path(context.codingPath))"
        case DecodingError.dataCorrupted(let context):
            return context.debugDescription
        default:
            return error.localizedDescription
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}
