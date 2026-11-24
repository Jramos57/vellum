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
        let opfPath = EPUBHref.path(try Self.rootfilePath(in: Self.read(container, from: archive)))
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

    /// The package document's path from `META-INF/container.xml`.
    ///
    /// Read with a pattern, not `XMLParser`: callers open the package while
    /// an `XMLParser` of their own is running (a chapter's pictures are found
    /// as its markup is parsed), and `XMLParser` can't run inside another one.
    static func rootfilePath(in container: Data) throws -> String {
        var text = Self.decodeXML(container)
        // A commented-out rootfile isn't one.
        while let open = text.range(of: "<!--") {
            guard let close = text.range(of: "-->", range: open.upperBound..<text.endIndex) else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
                break
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let pattern = #"<(?:[A-Za-z_][\w.-]*:)?rootfile\b[^>]*?\bfull-path\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else {
            throw VellumError.ioFailure("container.xml names no rootfile full-path.")
        }
        let value = [1, 2].lazy.compactMap { index -> String? in
            let group = match.range(at: index)
            guard group.location != NSNotFound, let bounds = Range(group, in: text) else { return nil }
            return String(text[bounds])
        }.first ?? ""
        let path = value
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !path.isEmpty else { throw VellumError.ioFailure("container.xml names an empty rootfile full-path.") }
        return path
    }

    /// XML bytes as text: UTF-16 when the document says so with a byte-order
    /// mark, UTF-8 otherwise.
    static func decodeXML(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
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
