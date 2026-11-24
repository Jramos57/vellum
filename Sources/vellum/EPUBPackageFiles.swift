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
        } catch ZipArchiveError.resourceLimitExceeded(let message) {
            throw VellumError.resourceLimitExceeded(message)
        } catch {
            throw VellumError.ioFailure("Failed to open EPUB archive at \(url.path): \(error.localizedDescription)")
        }
        guard let container = files[Internal.containerPath] else {
            throw VellumError.ioFailure("Missing \(Internal.containerPath).")
        }
        let rootfile = try ContainerParser.parseRootfile(Self.read(container, from: archive))
        guard !Self.isUnsafe(rootfile.path) else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "PAR031",
                    specRule: "EPUB Container Rootfile Path Safety",
                    filePath: Internal.containerPath,
                    message: "container.xml rootfile path is unsafe.",
                    hint: "Use a package-relative OPF path without absolute or traversal segments."
                )
            ])
        }
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

    /// Whether a normalized archive path left the archive (or names nothing).
    private static func escapes(_ joined: String) -> Bool {
        joined.isEmpty || joined == ".." || joined.hasPrefix("../") || joined.hasPrefix("/")
    }

    /// Whether a container or href path is unsafe as spelled: absolute, a
    /// scheme, a NUL, or climbing out (the parser's rule, PAR031).
    private static func isUnsafe(_ path: String) -> Bool {
        let decoded = path.removingPercentEncoding ?? path
        let slashed = decoded.replacingOccurrences(of: "\\", with: "/")
        return decoded.hasPrefix("/") || decoded.hasPrefix("\\") || decoded.contains("\0") || EPUBHref.hasScheme(decoded)
            || slashed == ".." || slashed.hasPrefix("../") || slashed.contains("/../")
    }

    /// The archive path of an already-decoded package path (no fragment, no
    /// percent escapes: `images/map #1.jpg`), or nil when it would leave the archive.
    public func archivePath(forPackagePath path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\0"),
              !EPUBHref.hasScheme(path) else { return nil }
        let joined = EPUBHref.normalizePath(opfDirectory.isEmpty ? path : opfDirectory + "/" + path)
        // Inside the archive, and a file, not the package directory itself.
        guard !Self.escapes(joined), joined != opfDirectory else { return nil }
        return joined
    }

    /// The archive path of a manifest href (fragment and percent escapes
    /// allowed), or nil when it would leave the archive. The path is checked
    /// both as spelled and decoded, since readers differ (`a%2fb/../../../x`).
    public func archivePath(forManifestPath href: String) -> String? {
        let spelled = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let decoded = spelled.removingPercentEncoding else { return nil }
        for form in [spelled, decoded] {
            guard !form.isEmpty, !form.hasPrefix("/"), !form.hasPrefix("\\"), !form.contains("\0"),
                  !EPUBHref.hasScheme(form) else { return nil }
            let joined = EPUBHref.normalizePath(opfDirectory.isEmpty ? form : opfDirectory + "/" + form)
            guard !Self.escapes(joined) else { return nil }
        }
        return archivePath(forPackagePath: decoded)
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
