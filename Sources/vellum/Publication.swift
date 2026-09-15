import Foundation

/// A location in a publication, expressed as a resource href and optional fragment.
///
/// Use this type as a lightweight anchor for restoring reading position in app state.
public struct Locator: Codable, Hashable, Sendable {
    /// The target resource href, relative to the OPF package base.
    public let href: String
    /// An optional fragment identifier without the leading `#`.
    public let fragment: String?

    /// Creates a new locator.
    ///
    /// - Parameters:
    ///   - href: The target resource href.
    ///   - fragment: Optional fragment identifier.
    public init(href: String, fragment: String? = nil) {
        self.href = href
        self.fragment = fragment
    }
}

/// A manifest resource exposed in app-facing form.
///
/// Resource bytes are optional. When opened from file/data with ``EPUBPublicationService``,
/// this value is populated for package resources that can be loaded.
public struct ResourceItem: Codable, Hashable, Sendable {
    /// The manifest item identifier.
    public let id: String
    /// The manifest item href.
    public let href: String
    /// The declared media type.
    public let mediaType: String
    /// Optional EPUB properties from the manifest item.
    public let properties: [String]
    /// Optional resource bytes loaded from the EPUB package.
    public let data: Data?

    /// Creates a resource item.
    ///
    /// - Parameters:
    ///   - id: The manifest item identifier.
    ///   - href: The package-relative href.
    ///   - mediaType: The declared media type.
    ///   - properties: Optional manifest properties.
    ///   - data: Optional raw bytes for the resource.
    public init(id: String, href: String, mediaType: String, properties: [String] = [], data: Data? = nil) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.properties = properties
        self.data = data
    }
}

/// A spine-resolved reading-order content item for display.
public struct ReadingOrderItem: Codable, Hashable, Sendable {
    /// The manifest/spine identifier.
    public let id: String
    /// The content document href.
    public let href: String
    /// A display title derived from navigation.
    public let title: String
    /// XHTML payload for rendering or transformation.
    public let xhtml: String
    /// Plain-text extraction of the content document.
    public let plainText: String
    /// The media type for this reading item.
    public let mediaType: String

    /// Creates a reading-order item.
    ///
    /// - Parameters:
    ///   - id: The content identifier.
    ///   - href: The content href.
    ///   - title: Display title.
    ///   - xhtml: XHTML source.
    ///   - plainText: Plain-text extraction.
    ///   - mediaType: The content media type.
    public init(
        id: String,
        href: String,
        title: String,
        xhtml: String,
        plainText: String,
        mediaType: String = "application/xhtml+xml"
    ) {
        self.id = id
        self.href = href
        self.title = title
        self.xhtml = xhtml
        self.plainText = plainText
        self.mediaType = mediaType
    }
}

/// A navigation node.
public struct NavigationItem: Codable, Hashable, Sendable {
    /// Display label.
    public let label: String
    /// Target href.
    public let href: String
    /// Nested navigation items.
    public let children: [NavigationItem]

    /// Creates a navigation item.
    ///
    /// - Parameters:
    ///   - label: Display label.
    ///   - href: Target href.
    ///   - children: Optional child nodes.
    public init(label: String, href: String, children: [NavigationItem] = []) {
        self.label = label
        self.href = href
        self.children = children
    }
}

/// Structured publication navigation sections.
public struct NavigationTree: Codable, Hashable, Sendable {
    /// Table of contents items.
    public let toc: [NavigationItem]
    /// Landmark items.
    public let landmarks: [NavigationItem]
    /// Page-list items.
    public let pageList: [NavigationItem]

    /// Creates a navigation tree.
    ///
    /// - Parameters:
    ///   - toc: Table of contents items.
    ///   - landmarks: Landmark items.
    ///   - pageList: Page-list items.
    public init(toc: [NavigationItem], landmarks: [NavigationItem] = [], pageList: [NavigationItem] = []) {
        self.toc = toc
        self.landmarks = landmarks
        self.pageList = pageList
    }
}

/// App-facing publication model resolved from an EPUB package.
///
/// `Publication` is intended to drive view models and editor workflows.
public struct Publication: Codable, Hashable, Sendable {
    /// Publication metadata.
    public let metadata: EPUBMetadata
    /// Spine-resolved reading order.
    public let readingOrder: [ReadingOrderItem]
    /// Navigation sections.
    public let navigation: NavigationTree
    /// Manifest resources.
    public let resources: [ResourceItem]
    /// Fast lookup index by manifest id.
    public let manifestIndex: [String: ResourceItem]
    /// Fast lookup index by normalized href.
    public let hrefIndex: [String: ResourceItem]
    /// Cover image resolved from EPUB 3 cover-image properties or legacy EPUB 2 metadata.
    public let coverResource: ResourceItem?

    /// Creates a publication model.
    ///
    /// - Parameters:
    ///   - metadata: Publication metadata.
    ///   - readingOrder: Spine-resolved reading items.
    ///   - navigation: Navigation sections.
    ///   - resources: Manifest resources.
    ///   - manifestIndex: Resource lookup by id.
    ///   - hrefIndex: Resource lookup by normalized href.
    ///   - coverResource: Resolved cover image resource.
    public init(
        metadata: EPUBMetadata,
        readingOrder: [ReadingOrderItem],
        navigation: NavigationTree,
        resources: [ResourceItem],
        manifestIndex: [String: ResourceItem],
        hrefIndex: [String: ResourceItem],
        coverResource: ResourceItem? = nil
    ) {
        self.metadata = metadata
        self.readingOrder = readingOrder
        self.navigation = navigation
        self.resources = resources
        self.manifestIndex = manifestIndex
        self.hrefIndex = hrefIndex
        self.coverResource = coverResource
    }

    /// Returns the reading-order item addressed by a locator.
    ///
    /// Fragment values are ignored for item lookup; matching is performed by normalized href.
    ///
    /// - Parameter locator: The locator to resolve.
    /// - Returns: The matching reading-order item, or `nil`.
    public func readingOrderItem(for locator: Locator) -> ReadingOrderItem? {
        let normalized = PublicationResolver.normalizeHref(locator.href)
        return readingOrder.first { PublicationResolver.normalizeHref($0.href) == normalized }
    }

    /// Returns the reading-order item with a matching id.
    ///
    /// - Parameter id: The reading item id.
    /// - Returns: The matching reading-order item, or `nil`.
    public func readingOrderItem(id: String) -> ReadingOrderItem? {
        readingOrder.first { $0.id == id }
    }

    /// Returns the reading-order item for a href.
    ///
    /// - Parameter href: A content href. Fragment values are ignored.
    /// - Returns: The matching reading-order item, or `nil`.
    public func readingOrderItem(href: String) -> ReadingOrderItem? {
        let normalized = PublicationResolver.normalizeHref(href)
        return readingOrder.first { PublicationResolver.normalizeHref($0.href) == normalized }
    }

    /// Returns the index of a reading-order item for a href.
    ///
    /// - Parameter href: A content href. Fragment values are ignored.
    /// - Returns: The zero-based index in `readingOrder`, or `nil`.
    public func readingOrderIndex(forHref href: String) -> Int? {
        let normalized = PublicationResolver.normalizeHref(href)
        return readingOrder.firstIndex { PublicationResolver.normalizeHref($0.href) == normalized }
    }

    /// Returns the next reading-order item after a href.
    ///
    /// - Parameter href: Current item href. Fragment values are ignored.
    /// - Returns: The next reading-order item, or `nil` at the end or if not found.
    public func nextReadingOrderItem(afterHref href: String) -> ReadingOrderItem? {
        guard let index = readingOrderIndex(forHref: href) else { return nil }
        let next = readingOrder.index(after: index)
        guard next < readingOrder.endIndex else { return nil }
        return readingOrder[next]
    }

    /// Returns the previous reading-order item before a href.
    ///
    /// - Parameter href: Current item href. Fragment values are ignored.
    /// - Returns: The previous reading-order item, or `nil` at the beginning or if not found.
    public func previousReadingOrderItem(beforeHref href: String) -> ReadingOrderItem? {
        guard let index = readingOrderIndex(forHref: href), index > readingOrder.startIndex else { return nil }
        return readingOrder[readingOrder.index(before: index)]
    }

    /// Returns a resource by manifest id.
    ///
    /// - Parameter id: Manifest identifier.
    /// - Returns: The matching resource, or `nil`.
    public func resource(id: String) -> ResourceItem? {
        manifestIndex[id]
    }

    /// Returns a resource by href.
    ///
    /// - Parameter href: Resource href. Fragment values are ignored.
    /// - Returns: The matching resource, or `nil`.
    public func resource(href: String) -> ResourceItem? {
        hrefIndex[PublicationResolver.normalizeHref(href)]
    }

    /// Returns normalized progress for a reading-order href.
    ///
    /// The value is in `(0, 1]` for valid hrefs, based on reading-order position.
    ///
    /// - Parameter href: Reading-order href. Fragment values are ignored.
    /// - Returns: A normalized progress value, or `nil` if href is not found.
    public func progress(forHref href: String) -> Double? {
        guard !readingOrder.isEmpty, let index = readingOrderIndex(forHref: href) else { return nil }
        return Double(index + 1) / Double(readingOrder.count)
    }
}
