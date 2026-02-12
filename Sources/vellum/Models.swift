import Foundation

public struct EPUBMetadata: Codable, Hashable, Sendable {
    public let identifier: String
    public let title: String
    public let creator: String
    public let language: String
    public let modified: Date
    public let publisher: String?
    public let description: String?
    public let rights: String?

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

public struct EPUBChapterInput: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let markdown: String
    public let fileName: String

    public init(id: String, title: String, markdown: String, fileName: String) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.fileName = fileName
    }
}

public struct EPUBAsset: Codable, Hashable, Sendable {
    public let id: String
    public let relativePath: String
    public let mediaType: String
    public let data: Data
    public let properties: [String]

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

public struct CreateRequest: Sendable {
    public let metadata: EPUBMetadata
    public let chapters: [EPUBChapterInput]
    public let assets: [EPUBAsset]
    public let includeLegacyNCX: Bool
    public let addFeatureDemoContent: Bool

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

public struct EPUBManifestItem: Codable, Hashable, Sendable {
    public let id: String
    public let href: String
    public let mediaType: String
    public let properties: [String]
    public let mediaOverlay: String?

    public init(id: String, href: String, mediaType: String, properties: [String] = [], mediaOverlay: String? = nil) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.properties = properties
        self.mediaOverlay = mediaOverlay
    }
}

public struct EPUBSpineItem: Codable, Hashable, Sendable {
    public let idref: String

    public init(idref: String) {
        self.idref = idref
    }
}

public struct EPUBTOCNode: Codable, Hashable, Sendable {
    public let label: String
    public let href: String

    public init(label: String, href: String) {
        self.label = label
        self.href = href
    }
}

public struct EPUBChapter: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let href: String
    public let xhtml: String
    public let plainText: String

    public init(id: String, title: String, href: String, xhtml: String, plainText: String) {
        self.id = id
        self.title = title
        self.href = href
        self.xhtml = xhtml
        self.plainText = plainText
    }
}

public struct EPUBBook: Codable, Hashable, Sendable {
    public let metadata: EPUBMetadata
    public let manifest: [EPUBManifestItem]
    public let spine: [EPUBSpineItem]
    public let toc: [EPUBTOCNode]
    public let chapters: [EPUBChapter]

    public init(
        metadata: EPUBMetadata,
        manifest: [EPUBManifestItem],
        spine: [EPUBSpineItem],
        toc: [EPUBTOCNode],
        chapters: [EPUBChapter]
    ) {
        self.metadata = metadata
        self.manifest = manifest
        self.spine = spine
        self.toc = toc
        self.chapters = chapters
    }

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

    public func renderPlainText() -> String {
        chapters.map(\.plainText).joined(separator: "\n\n")
    }
}
