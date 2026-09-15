import Foundation

/// Versioned plain-text normal form used by ``EPUBChapter/plainText`` and
/// ``ReadingOrderItem/plainText``.
///
/// Anchoring schemes that store character offsets into chapter text must record
/// this version. When the version changes, previously stored offsets may need to
/// be re-resolved against the new text.
public enum VellumTextNormalization {
    /// Version of the current plain-text rules.
    public static let version = 1
}

/// Converts XHTML content documents into block-aware plain text.
///
/// Rules (version 1):
/// - Content in `head`, `script`, and `style` elements is discarded.
/// - Block-level elements and `br` insert line breaks between blocks.
/// - Inline elements are joined without breaks.
/// - Runs of whitespace (including non-breaking spaces) collapse to single spaces.
/// - Named and numeric character references are decoded.
/// - Zero-width characters (`zwnj`, `zwj`, `shy`, `lrm`, `rlm`) are removed.
enum PlainTextExtractor {
    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "center",
        "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
        "h5", "h6", "header", "hr", "html", "legend", "li", "main", "menu",
        "nav", "ol", "p", "pre", "section", "summary", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "ul"
    ]

    private static let rawTextElements: Set<String> = ["script", "style", "head", "title"]

    private static let voidElements: Set<String> = [
        "area", "base", "col", "embed", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"
    ]

    private static let zeroWidthEntities: Set<String> = ["shy", "zwnj", "zwj", "lrm", "rlm"]

    private static let entityScalars: [String: UInt32] = [
        "amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39,
        "nbsp": 160, "ensp": 8194, "emsp": 8195, "thinsp": 8201,
        "shy": 173, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207,
        "mdash": 8212, "ndash": 8211, "hellip": 8230,
        "lsquo": 8216, "rsquo": 8217, "ldquo": 8220, "rdquo": 8221,
        "laquo": 171, "raquo": 187, "lsaquo": 8249, "rsaquo": 8250,
        "sect": 167, "para": 182, "middot": 183, "bull": 8226,
        "dagger": 8224, "Dagger": 8225, "permil": 8240,
        "prime": 8242, "Prime": 8243, "deg": 176,
        "plusmn": 177, "times": 215, "divide": 247, "micro": 181,
        "sup2": 178, "sup3": 179, "frac12": 189, "frac14": 188, "frac34": 190,
        "fnof": 402, "circ": 710, "tilde": 732,
        "copy": 169, "reg": 174, "trade": 8482,
        "euro": 8364, "cent": 162, "pound": 163, "yen": 165, "curren": 164,
        "brvbar": 166, "uml": 168, "macr": 175, "acute": 180, "cedil": 184,
        "iexcl": 161, "iquest": 191, "ordf": 170, "ordm": 186, "not": 172,
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196,
        "Aring": 197, "AElig": 198, "Ccedil": 199, "OElig": 338,
        "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203,
        "Igrave": 204, "Iacute": 205, "Icirc": 206, "Iuml": 207,
        "Ntilde": 209,
        "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213, "Ouml": 214,
        "Oslash": 216,
        "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221,
        "szlig": 223,
        "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228,
        "aring": 229, "aelig": 230, "ccedil": 231, "oelig": 339,
        "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235,
        "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239,
        "ntilde": 241,
        "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246,
        "oslash": 248,
        "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253,
        "yuml": 255, "Scaron": 352, "scaron": 353
    ]

    static func plainText(fromXHTML xhtml: String) -> String {
        let characters = Array(xhtml)
        var output = OutputBuilder()
        var index = 0
        var rawTextElement: String?

        while index < characters.count {
            let character = characters[index]

            if let rawElement = rawTextElement {
                if character == "<", matchesClosingTag(characters, at: index, element: rawElement) {
                    var end = index
                    while end < characters.count, characters[end] != ">" {
                        end += 1
                    }
                    rawTextElement = nil
                    index = min(end + 1, characters.count)
                } else {
                    index += 1
                }
                continue
            }

            if character != "<" {
                var text = ""
                while index < characters.count, characters[index] != "<" {
                    text.append(characters[index])
                    index += 1
                }
                output.appendText(decodeEntities(in: text))
                continue
            }

            if matches(characters, at: index, "<!--") {
                index = skip(until: "-->", in: characters, from: index + 4)
                continue
            }

            if matches(characters, at: index, "<![CDATA[") {
                let contentStart = index + 9
                let end = find("]]>", in: characters, from: contentStart) ?? characters.count
                output.appendText(String(characters[contentStart..<end]))
                index = min(end + 3, characters.count)
                continue
            }

            if matches(characters, at: index, "<!") {
                index = skipDeclaration(in: characters, from: index + 2)
                continue
            }

            if matches(characters, at: index, "<?") {
                index = skip(until: "?>", in: characters, from: index + 2)
                continue
            }

            var cursor = index + 1
            var isClosing = false
            if cursor < characters.count, characters[cursor] == "/" {
                isClosing = true
                cursor += 1
            }

            let nameStart = cursor
            while cursor < characters.count, isNameCharacter(characters[cursor]) {
                cursor += 1
            }
            let name = String(characters[nameStart..<cursor]).lowercased()

            var end = cursor
            var quote: Character?
            while end < characters.count {
                let current = characters[end]
                if let openQuote = quote {
                    if current == openQuote { quote = nil }
                } else if current == "\"" || current == "'" {
                    quote = current
                } else if current == ">" {
                    break
                }
                end += 1
            }

            var probe = end - 1
            while probe > cursor, characters[probe].isWhitespace {
                probe -= 1
            }
            let isSelfClosing = probe >= cursor && characters[probe] == "/"

            if name.isEmpty {
                index += 1
                continue
            }

            handleTag(
                name: name,
                isClosing: isClosing,
                isSelfClosing: isSelfClosing,
                output: &output,
                rawTextElement: &rawTextElement
            )

            index = min(end + 1, characters.count)
        }

        return output.finish()
    }

    private static func handleTag(
        name: String,
        isClosing: Bool,
        isSelfClosing: Bool,
        output: inout OutputBuilder,
        rawTextElement: inout String?
    ) {
        if isClosing {
            if blockElements.contains(name) {
                output.appendBreak()
            }
            return
        }

        if name == "br" || name == "hr" {
            output.appendBreak()
            return
        }

        if rawTextElements.contains(name) {
            rawTextElement = name
            return
        }

        if voidElements.contains(name) {
            return
        }

        if blockElements.contains(name) {
            output.appendBreak()
        }
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "-"
            || character == "_" || character == ":"
    }

    private static func matchesClosingTag(_ characters: [Character], at index: Int, element: String) -> Bool {
        guard index + 2 <= characters.count,
              index < characters.count,
              characters[index] == "<",
              index + 1 < characters.count,
              characters[index + 1] == "/" else {
            return false
        }

        var cursor = index + 2
        let nameStart = cursor
        while cursor < characters.count, isNameCharacter(characters[cursor]) {
            cursor += 1
        }
        return String(characters[nameStart..<cursor]).lowercased() == element
    }

    private static func matches(_ characters: [Character], at index: Int, _ prefix: String) -> Bool {
        let prefixCharacters = Array(prefix)
        guard index + prefixCharacters.count <= characters.count else { return false }
        for offset in 0..<prefixCharacters.count where characters[index + offset] != prefixCharacters[offset] {
            return false
        }
        return true
    }

    private static func find(_ needle: String, in characters: [Character], from start: Int) -> Int? {
        let needleCharacters = Array(needle)
        guard !needleCharacters.isEmpty, start < characters.count else { return nil }

        var index = start
        while index + needleCharacters.count <= characters.count {
            var offset = 0
            var matched = true
            while offset < needleCharacters.count {
                if characters[index + offset] != needleCharacters[offset] {
                    matched = false
                    break
                }
                offset += 1
            }
            if matched {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func skip(until terminator: String, in characters: [Character], from start: Int) -> Int {
        guard let end = find(terminator, in: characters, from: start) else {
            return characters.count
        }
        return min(end + terminator.count, characters.count)
    }

    private static func skipDeclaration(in characters: [Character], from start: Int) -> Int {
        var index = start
        var quote: Character?
        var bracketDepth = 0

        while index < characters.count {
            let character = characters[index]
            if let openQuote = quote {
                if character == openQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == ">", bracketDepth == 0 {
                return index + 1
            }
            index += 1
        }

        return characters.count
    }

    static func decodeEntities(in text: String) -> String {
        guard text.contains("&") else { return text }

        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        var index = 0

        while index < characters.count {
            guard characters[index] == "&" else {
                result.append(characters[index])
                index += 1
                continue
            }

            let limit = min(characters.count, index + 34)
            var end = index + 1
            while end < limit, characters[end] != ";" {
                end += 1
            }

            guard end < limit, characters[end] == ";",
                  let decoded = decodeEntityBody(String(characters[(index + 1)..<end])) else {
                result.append(characters[index])
                index += 1
                continue
            }

            result.append(decoded)
            index = end + 1
        }

        return result
    }

    private static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            guard let value = UInt32(body.dropFirst(2), radix: 16), let scalar = UnicodeScalar(value) else {
                return nil
            }
            return String(Character(scalar))
        }

        if body.hasPrefix("#") {
            guard let value = UInt32(body.dropFirst()), let scalar = UnicodeScalar(value) else {
                return nil
            }
            return String(Character(scalar))
        }

        guard let value = entityScalars[body], let scalar = UnicodeScalar(value) else {
            return nil
        }
        return zeroWidthEntities.contains(body) ? "" : String(Character(scalar))
    }

    /// Replaces named character references with numeric references so strict XML
    /// parsers accept documents that rely on HTML entity sets.
    static func replacingNamedEntitiesWithNumericReferences(in text: String) -> String {
        guard text.contains("&") else { return text }

        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        var index = 0

        while index < characters.count {
            guard characters[index] == "&" else {
                result.append(characters[index])
                index += 1
                continue
            }

            let limit = min(characters.count, index + 34)
            var end = index + 1
            while end < limit, characters[end] != ";" {
                end += 1
            }

            guard end < limit, characters[end] == ";",
                  let value = entityScalars[String(characters[(index + 1)..<end])] else {
                result.append("&")
                index += 1
                continue
            }

            result.append("&#\(value);")
            index = end + 1
        }

        return result
    }
}

private struct OutputBuilder {
    private var text = ""
    private var pendingSpace = false

    mutating func appendText(_ chunk: String) {
        guard !chunk.isEmpty else { return }

        var collapsed = ""
        var previousWasWhitespace = false
        for character in chunk {
            if character.isWhitespace {
                if !previousWasWhitespace {
                    collapsed.append(" ")
                }
                previousWasWhitespace = true
            } else {
                collapsed.append(character)
                previousWasWhitespace = false
            }
        }

        guard !collapsed.isEmpty else { return }

        let hasLeadingSpace = collapsed.hasPrefix(" ")
        let hasTrailingSpace = collapsed.hasSuffix(" ")

        if hasLeadingSpace {
            pendingSpace = true
        }

        var core = collapsed
        if hasLeadingSpace, !core.isEmpty { core.removeFirst() }
        if hasTrailingSpace, !core.isEmpty { core.removeLast() }

        if !core.isEmpty {
            if pendingSpace, !isAtLineStart {
                text.append(" ")
            }
            text.append(core)
            pendingSpace = false
        }

        if hasTrailingSpace {
            pendingSpace = true
        }
    }

    mutating func appendBreak() {
        pendingSpace = false
        while text.hasSuffix(" ") {
            text.removeLast()
        }
        if !text.isEmpty, !text.hasSuffix("\n") {
            text.append("\n")
        }
    }

    mutating func finish() -> String {
        pendingSpace = false
        var result = text
        while result.hasSuffix(" ") || result.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }

    private var isAtLineStart: Bool {
        text.isEmpty || text.hasSuffix("\n")
    }
}
