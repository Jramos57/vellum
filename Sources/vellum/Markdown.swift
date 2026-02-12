import Foundation

enum MarkdownConverter {
    static func markdownToXHTMLBody(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var body: [String] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let text = paragraphBuffer.joined(separator: " ").xmlEscaped()
            body.append("<p>\(text)</p>")
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.hasPrefix("# ") {
                flushParagraph()
                body.append("<h1>\(String(line.dropFirst(2)).xmlEscaped())</h1>")
            } else if line.hasPrefix("## ") {
                flushParagraph()
                body.append("<h2>\(String(line.dropFirst(3)).xmlEscaped())</h2>")
            } else if line.hasPrefix("### ") {
                flushParagraph()
                body.append("<h3>\(String(line.dropFirst(4)).xmlEscaped())</h3>")
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraphBuffer.append(line)
            }
        }
        flushParagraph()
        return body.joined(separator: "\n")
    }

    static func plainText(fromXHTML xhtml: String) -> String {
        var text = xhtml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
