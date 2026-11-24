import Foundation

/// Reads single package files (a chapter's images, a stylesheet) straight
/// from an EPUB archive, without extracting it.
///
/// Opening maps the archive and reads its central directory once; each read
/// inflates only the requested entry. Reads are serialized, so one instance
/// can be shared by the threads that lay out a book or serve a web view.
public final class EPUBPackageFiles: @unchecked Sendable {
    private let archive: ZipArchiveReader
    /// Entries by their safe archive path.
    private let files: [String: ZipEntry]
    /// The package document's directory, which manifest hrefs resolve against
    /// ("" when the package document is at the archive root).
    public let opfDirectory: String
    private let lock = NSLock()

    /// Opens the archive and finds the package document exactly as the book
    /// parser does (`container.xml`'s last rootfile), so pictures come from
    /// the same rendition as the chapters.
    ///
    /// Opening parses `container.xml` with `XMLParser`, which can't run inside
    /// another `XMLParser`: open the package before parsing chapters, never
    /// from a parser callback.
    ///
    /// - Throws: ``VellumError`` when the file isn't a readable EPUB archive.
    public init(url: URL) throws {
        let archive: ZipArchiveReader
        var files: [String: ZipEntry] = [:]
        do {
            archive = try ZipArchiveReader(url: url)
            for entry in archive.entries where !entry.isDirectory {
                files[try ZipTool.safeExtractionPath(for: entry.path)] = entry
            }
        } catch let error as VellumError {
            throw error
        } catch {
            throw VellumError.ioFailure("Failed to open EPUB archive at \(url.path): \(error.localizedDescription)")
        }
        guard let container = files[Internal.containerPath] else {
            throw VellumError.ioFailure("Missing \(Internal.containerPath).")
        }
        let rootfile = try ContainerParser.parseRootfile(Self.read(container, from: archive))
        let opfPath = EPUBHref.path(rootfile.path)
        self.archive = archive
        self.files = files
        opfDirectory = opfPath.split(separator: "/").dropLast().joined(separator: "/")
    }

    private static func read(_ entry: ZipEntry, from archive: ZipArchiveReader) throws -> Data {
        do {
            return try archive.data(for: entry)
        } catch ZipArchiveError.resourceLimitExceeded(let message) {
            throw VellumError.resourceLimitExceeded(message)
        } catch {
            throw VellumError.ioFailure("Failed to read \(entry.path): \(error.localizedDescription)")
        }
    }

    /// The archive path of an already-decoded package path (no fragment, no
    /// percent escapes: `images/map #1.jpg`), or nil when it would leave the archive.
    public func archivePath(forPackagePath path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\0"),
              !EPUBHref.hasScheme(path) else { return nil }
        let joined = EPUBHref.normalizePath(opfDirectory.isEmpty ? path : opfDirectory + "/" + path)
        guard !joined.isEmpty, !joined.hasPrefix(".."), !joined.hasPrefix("/") else { return nil }
        return joined
    }

    /// The bytes at an already-decoded package path, or nil when the archive
    /// has no such file. Use this for a path that was decoded once already, so
    /// an escaped `#` or `%` in a file name isn't read twice.
    public func data(atPackagePath path: String) throws -> Data? {
        guard let archivePath = archivePath(forPackagePath: path) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = files[archivePath] else { return nil }
        return try Self.read(entry, from: archive)
    }

    /// The archive path of a manifest-relative path, or nil when it would
    /// leave the archive.
    public func archivePath(forManifestPath path: String) -> String? {
        let raw = path.removingPercentEncoding ?? path
        guard !raw.hasPrefix("/"), !raw.hasPrefix("\\"), !raw.contains("\0"), !EPUBHref.hasScheme(raw) else { return nil }
        let decoded = EPUBHref.path(path)
        guard !decoded.isEmpty else { return nil }
        let joined = EPUBHref.normalizePath(opfDirectory.isEmpty ? decoded : opfDirectory + "/" + decoded)
        guard !joined.isEmpty, !joined.hasPrefix(".."), !joined.hasPrefix("/") else { return nil }
        return joined
    }

    /// The bytes at a manifest-relative path (`images/map.jpg` for a package
    /// document in `OEBPS/`), or nil when the archive has no such file.
    ///
    /// - Throws: ``VellumError`` when the entry exists but can't be inflated
    ///   or is over the archive's per-entry limit.
    public func data(atManifestPath path: String) throws -> Data? {
        guard let archivePath = archivePath(forManifestPath: path) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = files[archivePath] else { return nil }
        return try Self.read(entry, from: archive)
    }
}
