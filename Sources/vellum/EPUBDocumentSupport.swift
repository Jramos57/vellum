import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// EPUB XML documents may use UTF-8 or UTF-16, with or without a BOM.
enum EPUBDocumentText {
    static func read(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let bytes = Array(data.prefix(4))
        let encoding: String.Encoding
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
        } else {
            // A UTF-16 declaration without a BOM needs its byte order inferred
            // before the declaration itself can be read.
            let signatureEncoding: String.Encoding = bytes.starts(with: [0x00, 0x3C, 0x00, 0x3F])
                ? .utf16BigEndian
                : bytes.starts(with: [0x3C, 0x00, 0x3F, 0x00]) ? .utf16LittleEndian : .isoLatin1
            let prefix = String(data: data.prefix(1024), encoding: signatureEncoding) ?? ""
            let pattern = #"^\s*<\?xml\b[^?]*\bencoding\s*=\s*["']([^"']+)["']"#
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
            let declared = match.flatMap { Range($0.range(at: 1), in: prefix) }.map { String(prefix[$0]).uppercased() }
            switch declared {
            case nil, "UTF-8": encoding = .utf8
            case "UTF-16": encoding = signatureEncoding == .utf16BigEndian ? .utf16BigEndian : .utf16LittleEndian
            case "UTF-16LE": encoding = .utf16LittleEndian
            case "UTF-16BE": encoding = .utf16BigEndian
            default:
                throw VellumError.ioFailure("Unsupported XML encoding in \(url.lastPathComponent): \(declared ?? "unknown").")
            }
        }
        guard var text = String(data: data, encoding: encoding) else {
            throw VellumError.ioFailure("Unable to decode \(url.lastPathComponent) as UTF-8 or UTF-16.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        // The text is Unicode now and is written back as UTF-8: a kept
        // `encoding="UTF-16"` would make a saved book unreadable.
        if encoding != .utf8 {
            text = text.replacingOccurrences(of: #"^(\s*<\?xml\b[^?]*?\bencoding\s*=\s*["'])[^"']+(["'])"#,
                                             with: "$1UTF-8$2", options: [.regularExpression, .caseInsensitive])
        }
        return text
    }

    /// Strings are re-encoded as UTF-8 for XMLParser. Remove the original
    /// encoding declaration so libxml2 does not interpret those bytes as UTF-16.
    static func parserData(from text: String) -> Data {
        let normalized = PlainTextExtractor.replacingNamedEntitiesWithNumericReferences(in: text)
        let pattern = #"^(\s*<\?xml\b[^?]*?)\s+encoding\s*=\s*["'][^"']+["']"#
        let rewritten = normalized.replacingOccurrences(of: pattern, with: "$1", options: [.regularExpression, .caseInsensitive])
        return Data(rewritten.utf8)
    }
}

/// Counts elements opened and closed. FoundationXML on Linux can report a
/// truncated document (`<package><metadata>`) as parsed, so well-formedness
/// also requires every element to close, the same on every platform.
final class XMLElementBalance: NSObject, XMLParserDelegate {
    private var depth = 0
    private var sawElement = false

    var isBalanced: Bool { sawElement && depth == 0 }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        sawElement = true
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
    }
}

/// Files every saved package generates itself, as decoded paths relative to
/// the package document's folder (`OEBPS/`). A chapter or asset there would
/// be overwritten, or would replace the package's own files.
enum EPUBGeneratedFiles {
    static func reserved(includeLegacyNCX: Bool) -> Set<String> {
        var paths: Set<String> = ["nav.xhtml", "content.opf", "../mimetype", "../META-INF/container.xml"]
        if includeLegacyNCX { paths.insert("toc.ncx") }
        return paths
    }

    static func isReserved(_ href: String, includeLegacyNCX: Bool) -> Bool {
        let key = EPUBHref.fileKey(href)
        return reserved(includeLegacyNCX: includeLegacyNCX).map(EPUBHref.fileKey).contains(key)
            || key.hasPrefix(EPUBHref.fileKey("../META-INF/"))
    }
}

/// Local href comparison uses decoded, normalized paths; stored hrefs retain
/// the manifest's spelling so reading locations remain source-compatible.
enum EPUBHref {
    /// The href for a literal file name: percent-encoded, so `Chapter 1.xhtml`
    /// is `Chapter%201.xhtml` and a literal `%` stays a `%` when decoded.
    static func encoding(fileName: String) -> String {
        fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
    }

    static func hasScheme(_ href: String) -> Bool {
        href.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
    }

    /// The file an href names on Apple's default file systems, which ignore
    /// case and Unicode composition: hrefs with one key are one file when
    /// saved, so `CHAPTER%31.xhtml` would overwrite `chapter1.xhtml`.
    static func fileKey(_ href: String) -> String {
        path(href).precomposedStringWithCanonicalMapping.lowercased()
    }

    static func path(_ href: String) -> String {
        let base = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return normalizePath(base.removingPercentEncoding ?? base)
    }

    static func normalizePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if component == "." { continue }
            if component == "..", let last = components.last, last != ".." {
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    static func resolve(_ href: String, relativeTo documentHref: String, manifest: [EPUBManifestItem]) -> String {
        if hasScheme(href) { return href }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let target = String(parts[0])
        let fragment = parts.count > 1 ? "#\(parts[1])" : ""
        let documentPath = path(documentHref)
        let directory = documentPath.split(separator: "/").dropLast().joined(separator: "/")
        let decodedTarget = target.removingPercentEncoding ?? target
        if decodedTarget.hasPrefix("/") || decodedTarget.hasPrefix("\\") { return decodedTarget + fragment }
        let resolved = target.isEmpty ? documentPath : normalizePath(directory + "/" + decodedTarget)
        let manifestHref = manifest.first(where: { path($0.href) == resolved })?.href
        return (manifestHref ?? resolved) + fragment
    }
}

/// Only encryption of documents needed for plain-text reading blocks opening.
enum EPUBEncryption {
    struct Entry {
        let algorithm: String
        let path: String

        var isFontObfuscation: Bool {
            algorithm == "http://www.idpf.org/2008/embedding" || algorithm == "http://ns.adobe.com/pdf/enc#RC"
        }
    }

    static func read(at url: URL) throws -> [Entry] {
        let delegate = Delegate()
        guard let data = try? Data(contentsOf: url) else { throw failure("Unable to read encryption.xml.") }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil, delegate.valid, delegate.hasRoot else {
            throw failure("Unable to parse encryption.xml safely.")
        }
        return delegate.entries
    }

    static func rejectRequiredDocuments(_ entries: [Entry], paths: Set<String>) throws {
        if let entry = entries.first(where: { paths.contains($0.path) }) {
            let reason = entry.isFontObfuscation
                ? "A required EPUB document is obfuscated: \(entry.path)."
                : "A required EPUB document is encrypted: \(entry.path)."
            throw failure(reason)
        }
    }

    private static func failure(_ message: String) -> VellumError {
        .unsupportedFeature(message, [.init(
            code: "PAR020",
            specRule: "EPUB OCF Encryption",
            filePath: "META-INF/encryption.xml",
            message: message,
            hint: "Use an EPUB with readable package, navigation, and content documents."
        )])
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        var valid = true
        var hasRoot = false
        private var depth = 0
        private var entryDepth: Int?
        private var cipherDataDepth: Int?
        private var algorithm: String?
        private var uri: String?
        private let encryptionNamespace = "http://www.w3.org/2001/04/xmlenc#"

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 1 {
                hasRoot = name == "encryption" && (namespaceURI == nil || namespaceURI == "" || namespaceURI == "urn:oasis:names:tc:opendocument:xmlns:container")
            }
            guard namespaceURI == encryptionNamespace else { return }
            switch name {
            case "EncryptedData":
                if entryDepth != nil { valid = false }
                entryDepth = depth
                algorithm = nil
                uri = nil
            case "EncryptionMethod" where entryDepth != nil:
                algorithm = attributes["Algorithm"]
            case "CipherData" where entryDepth != nil:
                cipherDataDepth = depth
            case "CipherReference" where cipherDataDepth == depth - 1:
                uri = attributes["URI"]
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if namespaceURI == encryptionNamespace, name == "EncryptedData", entryDepth == depth {
                if let algorithm, !algorithm.isEmpty, let uri, !uri.isEmpty {
                    entries.append(Entry(algorithm: algorithm, path: EPUBHref.path(uri)))
                } else {
                    valid = false
                }
                entryDepth = nil
            }
            if cipherDataDepth == depth { cipherDataDepth = nil }
            depth -= 1
        }
    }
}
