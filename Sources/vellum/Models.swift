import Foundation

/// Core publication metadata used when creating and parsing EPUB packages.
public struct EPUBMetadata: Codable, Hashable, Sendable {
    /// Stable publication identifier, typically a URN UUID.
    public let identifier: String
    /// Human-readable publication title.
    public let title: String
    /// Primary creator or author.
    public let creator: String
    /// BCP 47 language code.
    public let language: String
    /// Last modified timestamp.
    public let modified: Date
    /// Optional publisher string.
    public let publisher: String?
    /// Optional description.
    public let description: String?
    /// Optional rights statement.
    public let rights: String?
    /// Subject headings (`dc:subject`), in package order.
    public let subjects: [String]
    /// The publication this one derives from (`dc:source`), such as a print ISBN URN.
    public let source: String?

    /// Creates publication metadata.
    ///
    /// - Parameters:
    ///   - identifier: Stable publication identifier.
    ///   - title: Publication title.
    ///   - creator: Primary creator or author.
    ///   - language: Language code.
    ///   - modified: Modified timestamp.
    ///   - publisher: Optional publisher.
    ///   - description: Optional description.
    ///   - rights: Optional rights statement.
    ///   - subjects: Subject headings.
    ///   - source: Source publication identifier.
    public init(
        identifier: String,
        title: String,
        creator: String,
        language: String = "en",
        modified: Date = Date(),
        publisher: String? = nil,
        description: String? = nil,
        rights: String? = nil,
        subjects: [String] = [],
        source: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.creator = creator
        self.language = language
        self.modified = modified
        self.publisher = publisher
        self.description = description
        self.rights = rights
        self.subjects = subjects
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, title, creator, language, modified, publisher, description, rights, subjects, source
    }

    /// Decodes metadata; `subjects` and `source` are optional so values encoded
    /// before they existed still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try c.decode(String.self, forKey: .identifier)
        title = try c.decode(String.self, forKey: .title)
        creator = try c.decode(String.self, forKey: .creator)
        language = try c.decode(String.self, forKey: .language)
        modified = try c.decode(Date.self, forKey: .modified)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        rights = try c.decodeIfPresent(String.self, forKey: .rights)
        subjects = try c.decodeIfPresent([String].self, forKey: .subjects) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// Input chapter model for EPUB creation.
///
/// A chapter is either Markdown, which vellum converts into its own XHTML
/// template, or a complete XHTML document, which is written to the package
/// byte for byte so the book's own markup, classes, stylesheet links, ids and
/// footnotes survive.
public struct EPUBChapterInput: Codable, Hashable, Sendable {
    /// Manifest/spine identifier.
    public let id: String
    /// Display title used for navigation and chapter heading.
    public let title: String
    /// Markdown source that will be transformed to XHTML. Ignored when ``xhtml`` is set.
    public let markdown: String
    /// Output content filename in the package.
    public let fileName: String
    /// A complete XHTML content document, written verbatim. It must be well-formed XML.
    public let xhtml: String?
    /// Whether the chapter belongs to the default reading order; `false` writes `linear="no"`.
    public let linear: Bool
    /// Whether the chapter is listed in the navigation document and NCX.
    public let includeInNavigation: Bool
    /// Manifest item properties, such as `svg`, `scripted` or `mathml`.
    public let properties: [String]

    /// Creates a Markdown chapter input.
    ///
    /// - Parameters:
    ///   - id: Manifest/spine identifier.
    ///   - title: Display title.
    ///   - markdown: Markdown source.
    ///   - fileName: Output filename.
    public init(id: String, title: String, markdown: String, fileName: String) {
        self.init(id: id, title: title, markdown: markdown, fileName: fileName, linear: true)
    }

    /// Creates a Markdown chapter input with reading-order and navigation options.
    ///
    /// - Parameters:
    ///   - id: Manifest/spine identifier.
    ///   - title: Display title.
    ///   - markdown: Markdown source.
    ///   - fileName: Output filename.
    ///   - linear: Whether the chapter is in the default reading order.
    ///   - includeInNavigation: Whether the chapter is listed in the navigation document.
    public init(id: String, title: String, markdown: String, fileName: String,
                linear: Bool, includeInNavigation: Bool = true) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.fileName = fileName
        self.xhtml = nil
        self.linear = linear
        self.includeInNavigation = includeInNavigation
        self.properties = []
    }

    /// Creates a chapter from a complete XHTML document that is packaged verbatim.
    ///
    /// - Parameters:
    ///   - id: Manifest/spine identifier.
    ///   - title: Navigation title; the document keeps its own headings.
    ///   - xhtml: The complete, well-formed XHTML document.
    ///   - fileName: Output filename.
    ///   - linear: Whether the chapter is in the default reading order.
    ///   - includeInNavigation: Whether the chapter is listed in the navigation document.
    ///   - properties: Manifest item properties.
    public init(id: String, title: String, xhtml: String, fileName: String,
                linear: Bool = true, includeInNavigation: Bool = true, properties: [String] = []) {
        self.id = id
        self.title = title
        self.markdown = ""
        self.fileName = fileName
        self.xhtml = xhtml
        self.linear = linear
        self.includeInNavigation = includeInNavigation
        self.properties = properties
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, markdown, fileName, xhtml, linear, includeInNavigation, properties
    }

    /// Decodes a chapter; every field added after `markdown` is optional, so
    /// chapters encoded by earlier versions still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        fileName = try c.decode(String.self, forKey: .fileName)
        xhtml = try c.decodeIfPresent(String.self, forKey: .xhtml)
        linear = try c.decodeIfPresent(Bool.self, forKey: .linear) ?? true
        includeInNavigation = try c.decodeIfPresent(Bool.self, forKey: .includeInNavigation) ?? true
        properties = try c.decodeIfPresent([String].self, forKey: .properties) ?? []
    }
}

/// A landmark written to the navigation document (`epub:type` landmarks).
public struct EPUBLandmark: Codable, Hashable, Sendable {
    /// Structural semantics, such as `bodymatter`, `toc`, `titlepage` or `backmatter`.
    public let type: String
    /// Display title.
    public let title: String
    /// Target chapter file name, optionally followed by `#fragment`.
    public let href: String

    /// Creates a landmark.
    ///
    /// - Parameters:
    ///   - type: Structural semantics (`epub:type`).
    ///   - title: Display title.
    ///   - href: Target chapter file name, optionally with a fragment.
    public init(type: String, title: String, href: String) {
        self.type = type
        self.title = title
        self.href = href
    }
}

/// Binary asset input for EPUB creation.
public struct EPUBAsset: Codable, Hashable, Sendable {
    /// Manifest identifier.
    public let id: String
    /// Package-relative asset path.
    public let relativePath: String
    /// Asset MIME media type.
    public let mediaType: String
    /// Raw asset bytes.
    public let data: Data
    /// Optional manifest properties.
    public let properties: [String]

    /// Creates an EPUB asset.
    ///
    /// - Parameters:
    ///   - id: Manifest identifier.
    ///   - relativePath: Package-relative asset path.
    ///   - mediaType: MIME media type.
    ///   - data: Raw asset bytes.
    ///   - properties: Optional manifest properties.
    public init(
        id: String,
        relativePath: String,
        mediaType: String,
        data: Data,
        properties: [String] = []
    ) {
        self.id = id
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.data = data
        self.properties = properties
    }
}

/// Request payload used by ``EPUBCreator``.
public struct CreateRequest: Sendable {
    /// Publication metadata.
    public let metadata: EPUBMetadata
    /// Ordered chapter inputs.
    public let chapters: [EPUBChapterInput]
    /// Additional package assets.
    public let assets: [EPUBAsset]
    /// Include EPUB 2 NCX compatibility output.
    public let includeLegacyNCX: Bool
    /// Include additional feature-demo resources in generated output.
    public let addFeatureDemoContent: Bool
    /// Landmarks for the navigation document; `nil` writes one `bodymatter`
    /// landmark at the first chapter.
    public let landmarks: [EPUBLandmark]?
    /// Write a page list with one generated "Page N" entry per chapter. Reading
    /// systems show page lists as print page numbers, so turn this off for
    /// books that carry their own pagination or none.
    public let includeGeneratedPageList: Bool

    /// Creates an EPUB build request.
    ///
    /// - Parameters:
    ///   - metadata: Publication metadata.
    ///   - chapters: Ordered chapter inputs.
    ///   - assets: Additional package assets.
    ///   - includeLegacyNCX: Include NCX compatibility output.
    ///   - addFeatureDemoContent: Include feature-demo resources.
    ///   - landmarks: Navigation landmarks, or `nil` for the default.
    ///   - includeGeneratedPageList: Write a generated per-chapter page list.
    public init(
        metadata: EPUBMetadata,
        chapters: [EPUBChapterInput],
        assets: [EPUBAsset] = [],
        includeLegacyNCX: Bool = true,
        addFeatureDemoContent: Bool = false,
        landmarks: [EPUBLandmark]? = nil,
        includeGeneratedPageList: Bool = true
    ) {
        self.metadata = metadata
        self.chapters = chapters
        self.assets = assets
        self.includeLegacyNCX = includeLegacyNCX
        self.addFeatureDemoContent = addFeatureDemoContent
        self.landmarks = landmarks
        self.includeGeneratedPageList = includeGeneratedPageList
    }
}

/// Manifest entry parsed from OPF.
public struct EPUBManifestItem: Codable, Hashable, Sendable {
    /// Item identifier.
    public let id: String
    /// Package-relative href.
    public let href: String
    /// Item media type.
    public let mediaType: String
    /// Optional EPUB properties.
    public let properties: [String]
    /// Optional media overlay reference id.
    public let mediaOverlay: String?

    /// Creates a manifest item.
    ///
    /// - Parameters:
    ///   - id: Item identifier.
    ///   - href: Package-relative href.
    ///   - mediaType: Item media type.
    ///   - properties: Optional properties.
    ///   - mediaOverlay: Optional media overlay reference.
    public init(id: String, href: String, mediaType: String, properties: [String] = [], mediaOverlay: String? = nil) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.properties = properties
        self.mediaOverlay = mediaOverlay
    }
}

/// Spine reference parsed from OPF.
public struct EPUBSpineItem: Codable, Hashable, Sendable {
    /// Manifest idref.
    public let idref: String
    /// Whether the item is in the default reading order (`linear="no"` is `false`).
    public let linear: Bool

    /// Creates a spine item.
    ///
    /// - Parameters:
    ///   - idref: Manifest id reference.
    ///   - linear: Whether the item is in the default reading order.
    public init(idref: String, linear: Bool = true) {
        self.idref = idref
        self.linear = linear
    }

    private enum CodingKeys: String, CodingKey { case idref, linear }

    /// Decodes a spine item; `linear` defaults to `true` for values encoded before it existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idref = try c.decode(String.self, forKey: .idref)
        linear = try c.decodeIfPresent(Bool.self, forKey: .linear) ?? true
    }
}

/// TOC node in document order, with its navigation nesting level.
public struct EPUBTOCNode: Codable, Hashable, Sendable {
    /// TOC label.
    public let label: String
    /// TOC target href.
    public let href: String
    /// Nesting level; zero identifies a top-level entry.
    public let level: Int

    /// Creates a TOC node.
    ///
    /// - Parameters:
    ///   - label: TOC label.
    ///   - href: TOC target href.
    ///   - level: Navigation nesting level.
    public init(label: String, href: String, level: Int = 0) {
        self.label = label
        self.href = href
        self.level = level
    }

    private enum CodingKeys: String, CodingKey {
        case label, href, level
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        href = try container.decode(String.self, forKey: .href)
        level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 0
    }
}

/// Parsed chapter payload from a spine content document.
public struct EPUBChapter: Codable, Hashable, Sendable {
    /// Manifest/spine identifier.
    public let id: String
    /// Display title, usually resolved from TOC.
    public let title: String
    /// Chapter href.
    public let href: String
    /// Original XHTML source.
    public let xhtml: String
    /// Extracted plain text.
    public let plainText: String

    /// Creates a chapter model.
    ///
    /// - Parameters:
    ///   - id: Manifest/spine identifier.
    ///   - title: Display title.
    ///   - href: Chapter href.
    ///   - xhtml: Original XHTML source.
    ///   - plainText: Extracted plain text.
    public init(id: String, title: String, href: String, xhtml: String, plainText: String) {
        self.id = id
        self.title = title
        self.href = href
        self.xhtml = xhtml
        self.plainText = plainText
    }
}

/// Low-level parse result returned by ``EPUBParser``.
///
/// For app-facing integration, prefer ``Publication`` from ``EPUBPublicationService``.
public struct EPUBBook: Codable, Hashable, Sendable {
    /// Publication metadata.
    public let metadata: EPUBMetadata
    /// Manifest items.
    public let manifest: [EPUBManifestItem]
    /// Spine references.
    public let spine: [EPUBSpineItem]
    /// Parsed TOC.
    public let toc: [EPUBTOCNode]
    /// Parsed chapter payloads.
    public let chapters: [EPUBChapter]
    /// Manifest id from a legacy EPUB 2 `<meta name="cover">` entry, when present.
    public let coverItemID: String?
    /// Href from a legacy `<guide>` cover reference, when present.
    public let coverGuideHref: String?
    /// Recoverable reading problems, reported as warnings in lenient mode.
    public let diagnostics: [VellumDiagnostic]
    /// The package's CSS, by manifest href, so a reader can honour the
    /// publisher's layout (heading alignment, fonts, indents).
    public let stylesheets: [String: String]

    /// Creates a parsed book model.
    ///
    /// - Parameters:
    ///   - metadata: Publication metadata.
    ///   - manifest: Manifest items.
    ///   - spine: Spine references.
    ///   - toc: Parsed TOC nodes.
    ///   - chapters: Parsed chapters.
    ///   - coverItemID: Legacy EPUB 2 cover manifest id.
    ///   - coverGuideHref: Legacy guide cover href.
    ///   - diagnostics: Recoverable parsing diagnostics.
    ///   - stylesheets: The package's CSS text by manifest href.
    public init(
        metadata: EPUBMetadata,
        manifest: [EPUBManifestItem],
        spine: [EPUBSpineItem],
        toc: [EPUBTOCNode],
        chapters: [EPUBChapter],
        coverItemID: String? = nil,
        coverGuideHref: String? = nil,
        diagnostics: [VellumDiagnostic] = [],
        stylesheets: [String: String] = [:]
    ) {
        self.metadata = metadata
        self.manifest = manifest
        self.spine = spine
        self.toc = toc
        self.chapters = chapters
        self.coverItemID = coverItemID
        self.coverGuideHref = coverGuideHref
        self.diagnostics = diagnostics
        self.stylesheets = stylesheets
    }

    private enum CodingKeys: String, CodingKey {
        case metadata, manifest, spine, toc, chapters, coverItemID, coverGuideHref, diagnostics, stylesheets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(EPUBMetadata.self, forKey: .metadata)
        manifest = try container.decode([EPUBManifestItem].self, forKey: .manifest)
        spine = try container.decode([EPUBSpineItem].self, forKey: .spine)
        toc = try container.decode([EPUBTOCNode].self, forKey: .toc)
        chapters = try container.decode([EPUBChapter].self, forKey: .chapters)
        coverItemID = try container.decodeIfPresent(String.self, forKey: .coverItemID)
        coverGuideHref = try container.decodeIfPresent(String.self, forKey: .coverGuideHref)
        diagnostics = try container.decodeIfPresent([VellumDiagnostic].self, forKey: .diagnostics) ?? []
        stylesheets = try container.decodeIfPresent([String: String].self, forKey: .stylesheets) ?? [:]
    }

    /// Renders parsed content as structured markdown for diagnostics or export.
    ///
    /// - Returns: A markdown document containing metadata, TOC, and chapter text.
    public func renderStructuredMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(metadata.title)")
        lines.append("")
        lines.append("- Identifier: \(metadata.identifier)")
        lines.append("- Author: \(metadata.creator)")
        lines.append("- Language: \(metadata.language)")
        lines.append("")
        lines.append("## Table of Contents")
        for entry in toc {
            lines.append("- [\(entry.label)](\(entry.href))")
        }
        lines.append("")
        lines.append("## Chapters")
        for chapter in chapters {
            lines.append("")
            lines.append("### \(chapter.title)")
            lines.append("")
            lines.append(chapter.plainText)
        }
        return lines.joined(separator: "\n")
    }

    /// Renders parsed content as concatenated plain text.
    ///
    /// - Returns: Chapter text joined with blank-line separators.
    public func renderPlainText() -> String {
        chapters.map(\.plainText).joined(separator: "\n\n")
    }
}
