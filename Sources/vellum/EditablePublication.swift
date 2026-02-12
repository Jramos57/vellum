import Foundation

/// Editable chapter payload for save workflows.
public struct EditableChapter: Codable, Hashable, Sendable {
    /// Manifest/spine identifier.
    public let id: String
    /// Package-relative content href.
    public let href: String
    /// Display title used for generated navigation.
    public let title: String
    /// XHTML content to serialize into the package.
    public let xhtml: String

    /// Creates an editable chapter.
    ///
    /// - Parameters:
    ///   - id: Manifest identifier.
    ///   - href: Package-relative href.
    ///   - title: Display title.
    ///   - xhtml: XHTML payload.
    public init(id: String, href: String, title: String, xhtml: String) {
        self.id = id
        self.href = href
        self.title = title
        self.xhtml = xhtml
    }
}

/// Editable non-spine asset payload for save workflows.
public struct EditableAsset: Codable, Hashable, Sendable {
    /// Manifest identifier.
    public let id: String
    /// Package-relative resource href.
    public let href: String
    /// MIME media type.
    public let mediaType: String
    /// Optional EPUB properties.
    public let properties: [String]
    /// Resource bytes.
    public let data: Data

    /// Creates an editable asset.
    ///
    /// - Parameters:
    ///   - id: Manifest identifier.
    ///   - href: Package-relative href.
    ///   - mediaType: MIME media type.
    ///   - properties: Optional EPUB properties.
    ///   - data: Resource bytes.
    public init(id: String, href: String, mediaType: String, properties: [String] = [], data: Data) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.properties = properties
        self.data = data
    }
}

/// Mutable publication payload used by the command-based editor.
public struct EditablePublication: Codable, Hashable, Sendable {
    /// Publication metadata.
    public let metadata: EPUBMetadata
    /// Ordered editable chapters.
    public let chapters: [EditableChapter]
    /// Editable non-spine assets.
    public let assets: [EditableAsset]
    /// Include EPUB 2 NCX compatibility output.
    public let includeLegacyNCX: Bool
    /// Optional explicit navigation tree override.
    public let navigationOverride: NavigationTree?
    /// Best-effort preserved unknown OPF metadata entries.
    public let preservedMetadataEntries: [String]

    /// Creates an editable publication.
    ///
    /// - Parameters:
    ///   - metadata: Publication metadata.
    ///   - chapters: Ordered editable chapters.
    ///   - assets: Editable non-spine assets.
    ///   - includeLegacyNCX: Include NCX compatibility output.
    ///   - navigationOverride: Optional explicit navigation override.
    ///   - preservedMetadataEntries: Preserved unknown OPF metadata entries.
    public init(
        metadata: EPUBMetadata,
        chapters: [EditableChapter],
        assets: [EditableAsset] = [],
        includeLegacyNCX: Bool = true,
        navigationOverride: NavigationTree? = nil,
        preservedMetadataEntries: [String] = []
    ) {
        self.metadata = metadata
        self.chapters = chapters
        self.assets = assets
        self.includeLegacyNCX = includeLegacyNCX
        self.navigationOverride = navigationOverride
        self.preservedMetadataEntries = preservedMetadataEntries
    }
}

/// Commands that mutate an ``EditablePublication``.
public enum EPUBEditCommand: Sendable {
    /// Replaces publication metadata.
    case updateMetadata(EPUBMetadata)
    /// Inserts a chapter at an index.
    case insertChapter(index: Int, chapter: EditableChapter)
    /// Updates chapter XHTML and optional title.
    case updateChapter(id: String, xhtml: String, title: String?)
    /// Removes a chapter by id.
    case removeChapter(id: String)
    /// Moves a chapter to a new index.
    case moveChapter(id: String, toIndex: Int)
    /// Adds an asset.
    case addAsset(EditableAsset)
    /// Removes an asset by id.
    case removeAsset(id: String)
    /// Sets or clears explicit navigation override.
    case setNavigationOverride(NavigationTree?)
}

/// Applies edit commands and validates editable publication integrity.
public struct EPUBPublicationEditor: Sendable {
    /// Creates an editor.
    public init() {}

    /// Creates an editable publication from a resolved publication.
    ///
    /// - Parameters:
    ///   - publication: Source publication.
    ///   - includeLegacyNCX: Include NCX compatibility output.
    ///   - preservedMetadataEntries: Preserved unknown OPF metadata entries.
    /// - Returns: Editable publication model.
    public func makeEditable(
        from publication: Publication,
        includeLegacyNCX: Bool = true,
        preservedMetadataEntries: [String] = []
    ) -> EditablePublication {
        let chapters = publication.readingOrder.map {
            EditableChapter(id: $0.id, href: $0.href, title: $0.title, xhtml: $0.xhtml)
        }
        let chapterIDs = Set(chapters.map(\.id))
        let assets = publication.resources.compactMap { resource -> EditableAsset? in
            if chapterIDs.contains(resource.id) { return nil }
            if resource.properties.contains("nav") { return nil }
            if resource.id == "nav" || resource.id == "ncx" { return nil }
            if resource.href == "nav.xhtml" || resource.href == "toc.ncx" { return nil }
            if resource.mediaType == "application/x-dtbncx+xml" { return nil }
            guard let data = resource.data else { return nil }
            return EditableAsset(
                id: resource.id,
                href: resource.href,
                mediaType: resource.mediaType,
                properties: resource.properties,
                data: data
            )
        }
        return EditablePublication(
            metadata: publication.metadata,
            chapters: chapters,
            assets: assets,
            includeLegacyNCX: includeLegacyNCX,
            navigationOverride: nil,
            preservedMetadataEntries: preservedMetadataEntries
        )
    }

    /// Applies a single edit command.
    ///
    /// The result is validated before being returned.
    ///
    /// - Parameters:
    ///   - command: Command to apply.
    ///   - editable: Source editable publication.
    /// - Returns: Updated editable publication.
    /// - Throws: ``VellumError/strictValidationFailed(_:)`` when validation fails.
    public func apply(_ command: EPUBEditCommand, to editable: EditablePublication) throws -> EditablePublication {
        switch command {
        case .updateMetadata(let metadata):
            return try validated(
                EditablePublication(
                    metadata: metadata,
                    chapters: editable.chapters,
                    assets: editable.assets,
                    includeLegacyNCX: editable.includeLegacyNCX,
                    navigationOverride: editable.navigationOverride,
                    preservedMetadataEntries: editable.preservedMetadataEntries
                )
            )
        case .insertChapter(let index, let chapter):
            var chapters = editable.chapters
            let target = max(0, min(index, chapters.count))
            chapters.insert(chapter, at: target)
            return try validated(
                EditablePublication(
                    metadata: editable.metadata,
                    chapters: chapters,
                    assets: editable.assets,
                    includeLegacyNCX: editable.includeLegacyNCX,
                    navigationOverride: editable.navigationOverride,
                    preservedMetadataEntries: editable.preservedMetadataEntries
                )
            )
        case .updateChapter(let id, let xhtml, let title):
            var chapters = editable.chapters
            guard let idx = chapters.firstIndex(where: { $0.id == id }) else {
                throw VellumError.strictValidationFailed([
                    .init(
                        code: "EDT001",
                        specRule: "Vellum Edit Chapter Existence",
                        message: "Cannot update chapter that does not exist.",
                        hint: "Pass a valid chapter id."
                    )
                ])
            }
            let old = chapters[idx]
            chapters[idx] = EditableChapter(
                id: old.id,
                href: old.href,
                title: title ?? old.title,
                xhtml: xhtml
            )
            return try validated(
                EditablePublication(
                    metadata: editable.metadata,
                    chapters: chapters,
                    assets: editable.assets,
                    includeLegacyNCX: editable.includeLegacyNCX,
                    navigationOverride: editable.navigationOverride,
                    preservedMetadataEntries: editable.preservedMetadataEntries
                )
            )
        case .removeChapter(let id):
            let chapters = editable.chapters.filter { $0.id != id }
            return try validated(
                EditablePublication(
                    metadata: editable.metadata,
                    chapters: chapters,
                    assets: editable.assets,
                    includeLegacyNCX: editable.includeLegacyNCX,
                    navigationOverride: editable.navigationOverride,
                    preservedMetadataEntries: editable.preservedMetadataEntries
                )
            )
        case .moveChapter(let id, let toIndex):
            var chapters = editable.chapters
            guard let oldIndex = chapters.firstIndex(where: { $0.id == id }) else {
                throw VellumError.strictValidationFailed([
                    .init(
                        code: "EDT001",
                        specRule: "Vellum Edit Chapter Existence",
                        message: "Cannot move chapter that does not exist.",
                        hint: "Pass a valid chapter id."
                    )
                ])
            }
            let chapter = chapters.remove(at: oldIndex)
            let target = max(0, min(toIndex, chapters.count))
            chapters.insert(chapter, at: target)
            return try validated(
                EditablePublication(
                    metadata: editable.metadata,
                    chapters: chapters,
                    assets: editable.assets,
                    includeLegacyNCX: editable.includeLegacyNCX,
                    navigationOverride: editable.navigationOverride,
                    preservedMetadataEntries: editable.preservedMetadataEntries
                )
            )
        case .addAsset(let asset):
            let assets = editable.assets + [asset]
            return try validated(
                EditablePublication(
                    metadata: editable.metadata,
                    chapters: editable.chapters,
                    assets: assets,
                    includeLegacyNCX: editable.includeLegacyNCX,
                    navigationOverride: editable.navigationOverride,
                    preservedMetadataEntries: editable.preservedMetadataEntries
                )
            )
        case .removeAsset(let id):
            let assets = editable.assets.filter { $0.id != id }
            return try validated(
                EditablePublication(
                    metadata: editable.metadata,
                    chapters: editable.chapters,
                    assets: assets,
                    includeLegacyNCX: editable.includeLegacyNCX,
                    navigationOverride: editable.navigationOverride,
                    preservedMetadataEntries: editable.preservedMetadataEntries
                )
            )
        case .setNavigationOverride(let navigation):
            return try validated(
                EditablePublication(
                    metadata: editable.metadata,
                    chapters: editable.chapters,
                    assets: editable.assets,
                    includeLegacyNCX: editable.includeLegacyNCX,
                    navigationOverride: navigation,
                    preservedMetadataEntries: editable.preservedMetadataEntries
                )
            )
        }
    }

    private func validated(_ editable: EditablePublication) throws -> EditablePublication {
        var diagnostics: [VellumDiagnostic] = []

        if editable.chapters.isEmpty {
            diagnostics.append(
                .init(
                    code: "EDT002",
                    specRule: "EPUB Package Spine",
                    message: "Editable publication must contain at least one chapter.",
                    hint: "Insert at least one chapter before saving."
                )
            )
        }

        let chapterIDDupes = Dictionary(grouping: editable.chapters, by: \.id).filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !chapterIDDupes.isEmpty {
            diagnostics.append(
                .init(
                    code: "EDT003",
                    specRule: "EPUB Manifest Unique IDs",
                    message: "Chapter ids must be unique.",
                    hint: "Ensure each chapter has a unique id."
                )
            )
        }
        let chapterHrefDupes = Dictionary(grouping: editable.chapters, by: \.href).filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !chapterHrefDupes.isEmpty {
            diagnostics.append(
                .init(
                    code: "EDT004",
                    specRule: "EPUB Manifest Unique HREFs",
                    message: "Chapter href values must be unique.",
                    hint: "Ensure each chapter href is unique."
                )
            )
        }

        for chapter in editable.chapters where isUnsafePath(chapter.href) {
            diagnostics.append(
                .init(
                    code: "EDT005",
                    specRule: "EPUB Resource Path Safety",
                    filePath: chapter.href,
                    message: "Chapter href is unsafe.",
                    hint: "Use package-relative href without absolute or traversal segments."
                )
            )
        }

        let allIDs = editable.chapters.map(\.id) + editable.assets.map(\.id)
        let duplicateIDs = Dictionary(grouping: allIDs, by: { $0 }).filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !duplicateIDs.isEmpty {
            diagnostics.append(
                .init(
                    code: "EDT006",
                    specRule: "EPUB Manifest Unique IDs",
                    message: "Chapter and asset ids must be globally unique.",
                    hint: "Use unique ids across all resources."
                )
            )
        }

        let allHrefs = editable.chapters.map(\.href) + editable.assets.map(\.href)
        let duplicateHrefs = Dictionary(grouping: allHrefs, by: { $0 }).filter { !$0.key.isEmpty && $0.value.count > 1 }
        if !duplicateHrefs.isEmpty {
            diagnostics.append(
                .init(
                    code: "EDT007",
                    specRule: "EPUB Manifest Unique HREFs",
                    message: "Chapter and asset href values must be globally unique.",
                    hint: "Use unique hrefs across all resources."
                )
            )
        }

        for asset in editable.assets {
            if isUnsafePath(asset.href) {
                diagnostics.append(
                    .init(
                        code: "EDT005",
                        specRule: "EPUB Resource Path Safety",
                        filePath: asset.href,
                        message: "Asset href is unsafe.",
                        hint: "Use package-relative href without absolute or traversal segments."
                    )
                )
            }
            if !isValidMediaType(asset.mediaType) {
                diagnostics.append(
                    .init(
                        code: "EDT008",
                        specRule: "EPUB Manifest Media Type Syntax",
                        filePath: asset.href,
                        message: "Asset media-type is invalid.",
                        hint: "Use MIME type syntax type/subtype."
                    )
                )
            }
        }

        if let navigation = editable.navigationOverride {
            let allowedHrefs = Set((editable.chapters.map(\.href) + editable.assets.map(\.href)).map(normalizeHref))
            let navHrefs = flattenNavigationItems(navigation.toc)
                + flattenNavigationItems(navigation.landmarks)
                + flattenNavigationItems(navigation.pageList)
            let invalid = navHrefs.filter { !allowedHrefs.contains(normalizeHref($0)) }
            if !invalid.isEmpty {
                diagnostics.append(
                    .init(
                        code: "EDT009",
                        specRule: "EPUB Navigation Target Validity",
                        message: "Navigation override contains href(s) not present in chapters/assets.",
                        hint: "Point navigation href values to known chapter or asset href values."
                    )
                )
            }
        }

        if !diagnostics.isEmpty {
            throw VellumError.strictValidationFailed(diagnostics)
        }
        return editable
    }

    private func isUnsafePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\") { return true }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.contains("../") || normalized.hasPrefix("..") { return true }
        return false
    }

    private func isValidMediaType(_ mediaType: String) -> Bool {
        let parts = mediaType.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let token = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy { token.contains($0) }
        }
    }

    private func normalizeHref(_ href: String) -> String {
        String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(href))
    }

    private func flattenNavigationItems(_ items: [NavigationItem]) -> [String] {
        items.flatMap { item in
            [item.href] + flattenNavigationItems(item.children)
        }
    }
}
