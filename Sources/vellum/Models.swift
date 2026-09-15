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
    public init(
        identifier: String,
        title: String,
        creator: String,
        language: String = "en",
        modified: Date = Date(),
        publisher: String? = nil,
        description: String? = nil,
        rights: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.creator = creator
        self.language = language
        self.modified = modified
        self.publisher = publisher
        self.description = description
        self.rights = rights
    }
}

/// Input chapter model for EPUB creation from markdown.
public struct EPUBChapterInput: Codable, Hashable, Sendable {
    /// Manifest/spine identifier.
    public let id: String
    /// Display title used for navigation and chapter heading.
    public let title: String
    /// Markdown source that will be transformed to XHTML.
    public let markdown: String
    /// Output content filename in the package.
    public let fileName: String

    /// Creates a chapter input.
    ///
    /// - Parameters:
    ///   - id: Manifest/spine identifier.
    ///   - title: Display title.
    ///   - markdown: Markdown source.
    ///   - fileName: Output filename.
    public init(id: String, title: String, markdown: String, fileName: String) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.fileName = fileName
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

    /// Creates an EPUB build request.
    ///
    /// - Parameters:
    ///   - metadata: Publication metadata.
    ///   - chapters: Ordered chapter inputs.
    ///   - assets: Additional package assets.
    ///   - includeLegacyNCX: Include NCX compatibility output.
    ///   - addFeatureDemoContent: Include feature-demo resources.
    public init(
        metadata: EPUBMetadata,
        chapters: [EPUBChapterInput],
        assets: [EPUBAsset] = [],
        includeLegacyNCX: Bool = true,
        addFeatureDemoContent: Bool = false
    ) {
        self.metadata = metadata
        self.chapters = chapters
        self.assets = assets
        self.includeLegacyNCX = includeLegacyNCX
        self.addFeatureDemoContent = addFeatureDemoContent
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

    /// Creates a spine item.
    ///
    /// - Parameter idref: Manifest id reference.
    public init(idref: String) {
        self.idref = idref
    }
}

/// Flat TOC node parsed from navigation.
public struct EPUBTOCNode: Codable, Hashable, Sendable {
    /// TOC label.
    public let label: String
    /// TOC target href.
    public let href: String

    /// Creates a TOC node.
    ///
    /// - Parameters:
    ///   - label: TOC label.
    ///   - href: TOC target href.
    public init(label: String, href: String) {
        self.label = label
        self.href = href
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
    public init(
        metadata: EPUBMetadata,
        manifest: [EPUBManifestItem],
        spine: [EPUBSpineItem],
        toc: [EPUBTOCNode],
        chapters: [EPUBChapter],
        coverItemID: String? = nil,
        coverGuideHref: String? = nil
    ) {
        self.metadata = metadata
        self.manifest = manifest
        self.spine = spine
        self.toc = toc
        self.chapters = chapters
        self.coverItemID = coverItemID
        self.coverGuideHref = coverGuideHref
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
