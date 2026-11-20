import Foundation
import Testing
@testable import vellum

private struct PlainTextFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let xhtml: String
    let expectedText: String
    let normalizationVersion = 1

    var testDescription: String { "v\(normalizationVersion): \(label)" }

    // Frozen XHTML/output pairs for the version 1 normalization contract.
    static let version1: [Self] = [
        .init(
            label: "separates paragraphs with line breaks",
            xhtml: """
            <html><body><p>First paragraph.</p><p>Second paragraph.</p></body></html>
            """,
            expectedText: "First paragraph.\nSecond paragraph."
        ),
        .init(
            label: "joins inline elements without breaks",
            xhtml: """
            <p>Hello <em>beautiful</em> <strong>world</strong>!</p>
            """,
            expectedText: "Hello beautiful world!"
        ),
        .init(
            label: "treats breaks and headings as block boundaries",
            xhtml: """
            <h1>Chapter One</h1><p>Line one<br/>line two</p><hr/><blockquote>Quoted text.</blockquote>
            """,
            expectedText: "Chapter One\nLine one\nline two\nQuoted text."
        ),
        .init(
            label: "collapses whitespace runs",
            xhtml: "<p>Spaced   out\n\ttext</p>",
            expectedText: "Spaced out text"
        ),
        .init(
            label: "decodes named and numeric entities",
            xhtml: """
            <p>Fish&nbsp;&amp;&nbsp;chips &#8212; &ldquo;nice&rdquo; &#x2014; &copy; 2026</p>
            """,
            expectedText: "Fish & chips \u{2014} \u{201C}nice\u{201D} \u{2014} \u{00A9} 2026"
        ),
        .init(
            label: "skips head script and style content",
            xhtml: """
            <html><head><title>Hidden</title><style>p { color: red; }</style></head>
            <body><script>if (a < b) { document.write("</p>"); }</script><p>Visible</p></body></html>
            """,
            expectedText: "Visible"
        ),
        .init(
            label: "skips comments and processing instructions",
            xhtml: """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <p>Before<!-- hidden <p>comment</p> -->After</p>
            """,
            expectedText: "BeforeAfter"
        ),
        .init(
            label: "handles CJK without inserting spaces",
            xhtml: "<p>\u{4F60}\u{597D}\u{4E16}\u{754C}</p><p>\u{7B2C}\u{4E8C}\u{6BB5}</p>",
            expectedText: "\u{4F60}\u{597D}\u{4E16}\u{754C}\n\u{7B2C}\u{4E8C}\u{6BB5}"
        ),
        .init(
            label: "drops empty blocks without stray breaks",
            xhtml: "<div></div><p></p><p>Content</p><p> </p><div><span></span></div>",
            expectedText: "Content"
        ),
        .init(
            label: "list items become separate lines",
            xhtml: "<ul><li>One</li><li>Two</li></ul>",
            expectedText: "One\nTwo"
        )
    ]
}

@Test("Plain text extraction preserves versioned examples", arguments: PlainTextFixture.version1)
private func plainTextExtractionMatchesFixture(fixture: PlainTextFixture) {
    #expect(VellumTextNormalization.version == fixture.normalizationVersion)
    #expect(MarkdownConverter.plainText(fromXHTML: fixture.xhtml) == fixture.expectedText)
}

@Test func namedEntityNormalizationProducesNumericReferences() {
    let xhtml = "<p>&nbsp;&amp;&unknown;&#8212;</p>"
    #expect(
        PlainTextExtractor.replacingNamedEntitiesWithNumericReferences(in: xhtml)
            == "<p>&#160;&#38;&unknown;&#8212;</p>"
    )
}
