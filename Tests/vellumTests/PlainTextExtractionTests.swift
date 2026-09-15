import Foundation
import Testing
@testable import vellum

@Test func plainTextSeparatesParagraphsWithLineBreaks() {
    let xhtml = """
    <html><body><p>First paragraph.</p><p>Second paragraph.</p></body></html>
    """
    #expect(MarkdownConverter.plainText(fromXHTML: xhtml) == "First paragraph.\nSecond paragraph.")
}

@Test func plainTextJoinsInlineElementsWithoutBreaks() {
    let xhtml = """
    <p>Hello <em>beautiful</em> <strong>world</strong>!</p>
    """
    #expect(MarkdownConverter.plainText(fromXHTML: xhtml) == "Hello beautiful world!")
}

@Test func plainTextTreatsBreaksAndHeadingsAsBlockBoundaries() {
    let xhtml = """
    <h1>Chapter One</h1><p>Line one<br/>line two</p><hr/><blockquote>Quoted text.</blockquote>
    """
    #expect(
        MarkdownConverter.plainText(fromXHTML: xhtml)
            == "Chapter One\nLine one\nline two\nQuoted text."
    )
}

@Test func plainTextCollapsesWhitespaceRuns() {
    let xhtml = "<p>Spaced   out\n\ttext</p>"
    #expect(MarkdownConverter.plainText(fromXHTML: xhtml) == "Spaced out text")
}

@Test func plainTextDecodesNamedAndNumericEntities() {
    let xhtml = """
    <p>Fish&nbsp;&amp;&nbsp;chips &#8212; &ldquo;nice&rdquo; &#x2014; &copy; 2026</p>
    """
    #expect(
        MarkdownConverter.plainText(fromXHTML: xhtml)
            == "Fish & chips \u{2014} \u{201C}nice\u{201D} \u{2014} \u{00A9} 2026"
    )
}

@Test func plainTextSkipsHeadScriptAndStyleContent() {
    let xhtml = """
    <html><head><title>Hidden</title><style>p { color: red; }</style></head>
    <body><script>if (a < b) { document.write("</p>"); }</script><p>Visible</p></body></html>
    """
    #expect(MarkdownConverter.plainText(fromXHTML: xhtml) == "Visible")
}

@Test func plainTextSkipsCommentsAndProcessingInstructions() {
    let xhtml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <p>Before<!-- hidden <p>comment</p> -->After</p>
    """
    #expect(MarkdownConverter.plainText(fromXHTML: xhtml) == "BeforeAfter")
}

@Test func plainTextHandlesCJKWithoutInsertingSpaces() {
    let xhtml = "<p>\u{4F60}\u{597D}\u{4E16}\u{754C}</p><p>\u{7B2C}\u{4E8C}\u{6BB5}</p>"
    #expect(MarkdownConverter.plainText(fromXHTML: xhtml) == "\u{4F60}\u{597D}\u{4E16}\u{754C}\n\u{7B2C}\u{4E8C}\u{6BB5}")
}

@Test func plainTextDropsEmptyBlocksWithoutStrayBreaks() {
    let xhtml = "<div></div><p></p><p>Content</p><p> </p><div><span></span></div>"
    #expect(MarkdownConverter.plainText(fromXHTML: xhtml) == "Content")
}

@Test func plainTextListItemsBecomeSeparateLines() {
    let xhtml = "<ul><li>One</li><li>Two</li></ul>"
    #expect(MarkdownConverter.plainText(fromXHTML: xhtml) == "One\nTwo")
}

@Test func namedEntityNormalizationProducesNumericReferences() {
    let xhtml = "<p>&nbsp;&amp;&unknown;&#8212;</p>"
    #expect(
        PlainTextExtractor.replacingNamedEntitiesWithNumericReferences(in: xhtml)
            == "<p>&#160;&#38;&unknown;&#8212;</p>"
    )
}

@Test func plainTextNormalizationVersionIsStable() {
    #expect(VellumTextNormalization.version == 1)
}
