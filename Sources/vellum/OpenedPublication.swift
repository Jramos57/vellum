import Foundation

/// The result of opening an EPUB: app-facing publication models plus disk-backed resources.
public struct OpenedPublication: Sendable {
    /// App-facing publication data.
    public let publication: Publication
    /// Disk-backed access to the extracted package resources.
    public let resources: PublicationResources

    /// Creates an opened publication result.
    ///
    /// - Parameters:
    ///   - publication: The resolved publication.
    ///   - resources: The extracted resource store.
    public init(publication: Publication, resources: PublicationResources) {
        self.publication = publication
        self.resources = resources
    }
}

/// Disk-backed access to the resources extracted from an opened EPUB package.
///
/// Opening a publication extracts the archive exactly once. Resources stay on disk so
/// large payloads are never forced into memory; load bytes on demand with
/// ``data(forHref:)`` or serve files directly with ``fileURL(forHref:)``.
///
/// When the resources instance created an extraction directory, that directory is
/// removed automatically when the instance is released. Call ``removeExtractedContent()``
/// to delete it earlier. After removal, file access methods return `nil` or throw.
public final class PublicationResources: Sendable {
    /// Root directory of the extracted EPUB package.
    public let rootURL: URL
    /// Directory containing the OPF package document; manifest hrefs resolve against it.
    public let opfBaseURL: URL

    private let normalizedHrefs: Set<String>
    private let managedRootURL: URL?

    init(rootURL: URL, opfBaseURL: URL, hrefs: [String], managedRootURL: URL?) {
        self.rootURL = rootURL
        self.opfBaseURL = opfBaseURL
        self.normalizedHrefs = Set(hrefs.map(PublicationResolver.normalizeHref))
        self.managedRootURL = managedRootURL
    }

    /// Returns the on-disk file URL for a manifest href.
    ///
    /// - Parameter href: A manifest href, with or without a fragment.
    /// - Returns: The extracted file URL, or `nil` when the href is unknown or missing.
    public func fileURL(forHref href: String) -> URL? {
        let normalized = PublicationResolver.normalizeHref(href)
        guard normalizedHrefs.contains(normalized) else { return nil }

        let url = opfBaseURL.appendingPathComponent(normalized)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Loads resource bytes from disk on demand.
    ///
    /// - Parameter href: A manifest href, with or without a fragment.
    /// - Returns: The resource bytes.
    /// - Throws: ``VellumError`` when the resource is unknown or unreadable.
    public func data(forHref href: String) throws -> Data {
        guard let url = fileURL(forHref: href) else {
            throw VellumError.ioFailure("No extracted resource found for href \(href).")
        }
        return try Data(contentsOf: url)
    }

    /// Returns whether an extracted file exists for a manifest href.
    ///
    /// - Parameter href: A manifest href, with or without a fragment.
    /// - Returns: `true` when the file is available on disk.
    public func contains(_ href: String) -> Bool {
        fileURL(forHref: href) != nil
    }

    /// Deletes the extracted package contents when this instance owns them.
    ///
    /// Safe to call multiple times. The instance must not be used for file access
    /// afterwards.
    public func removeExtractedContent() {
        guard let managedRootURL else { return }
        try? FileManager.default.removeItem(at: managedRootURL)
    }

    deinit {
        removeExtractedContent()
    }
}
