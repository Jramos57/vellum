# vellum

Strict Swift library for EPUB creation, parsing, and text extraction.

`vellum` is designed as a processing engine you can embed into your app pipeline before UI integration.

## Status

- Swift 6 package
- Apple platforms: macOS, iOS, tvOS, watchOS, visionOS
- Strict validation mode
- EPUB create + parse + markdown/plain-text output
- Sample 10-chapter lorem ipsum EPUB generator
- Navigation + manifest + spine integrity validation
- EPUB2 NCX fallback parsing

## Standards Baseline

`vellum` uses W3C EPUB standards as the normative reference:

- [EPUB 3.3](https://www.w3.org/TR/epub-33/)
- [EPUB Reading Systems 3.3](https://www.w3.org/TR/epub-rs-33/)
- [EPUB Accessibility 1.1](https://www.w3.org/TR/epub-a11y-11/)

Specification mapping is documented in:

- `Documentation/STANDARDS_MAPPING.md`

## Install

```swift
dependencies: [
    .package(url: "https://github.com/YOUR_ORG/vellum.git", from: "0.1.0")
]
```

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["vellum"]
    )
]
```

## Quick Start

### Create a sample 10-chapter EPUB

```swift
import Foundation
import vellum

let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 10)
let output = URL(fileURLWithPath: "/tmp/lorem.epub")
try EPUBCreator().createEPUB(request, outputURL: output)
```

### Parse an EPUB and export text

```swift
import Foundation
import vellum

let url = URL(fileURLWithPath: "/tmp/lorem.epub")
let book = try EPUBParser().parseEPUB(at: url)

let markdown = book.renderStructuredMarkdown()
let plainText = book.renderPlainText()
```

### Create your own EPUB from markdown

```swift
import Foundation
import vellum

let metadata = EPUBMetadata(
    identifier: "urn:uuid:\(UUID().uuidString)",
    title: "My Book",
    creator: "You"
)

let chapters = [
    EPUBChapterInput(
        id: "c1",
        title: "Chapter 1",
        markdown: "# Chapter 1\n\nHello EPUB.",
        fileName: "chapter1.xhtml"
    )
]

let request = CreateRequest(
    metadata: metadata,
    chapters: chapters,
    includeLegacyNCX: true,
    addFeatureDemoContent: true
)

try EPUBCreator().createEPUB(request, outputURL: URL(fileURLWithPath: "/tmp/mybook.epub"))
```

### Create EPUB from a markdown folder

```swift
let metadata = EPUBMetadata(
    identifier: "urn:uuid:\(UUID().uuidString)",
    title: "Folder Book",
    creator: "You"
)

try EPUBCreator().createEPUB(
    metadata: metadata,
    markdownDirectory: URL(fileURLWithPath: "/tmp/book-md"),
    outputURL: URL(fileURLWithPath: "/tmp/folder-book.epub")
)
```

## API Surface

- `EPUBCreator`
  - `createEPUB(_:outputURL:) throws`
  - `createEPUB(_:outputURL:) async throws`
  - `createEPUB(metadata:markdownDirectory:outputURL:...) throws`
  - `createEPUB(metadata:markdownDirectory:outputURL:...) async throws`
- `EPUBParser`
  - `parseEPUB(at:) throws -> EPUBBook`
  - `parseEPUB(at:) async throws -> EPUBBook`
- `EPUBValidator`
  - `validateEPUB(at:) -> ValidationReport`
  - `validateEPUB(at:) async -> ValidationReport`
- `SampleBookFactory`
  - `makeLoremIpsumBook(chapterCount:)`
- `EPUBBook`
  - `renderStructuredMarkdown()`
  - `renderPlainText()`

## Strict Validation

`vellum` fails fast for invalid structures and returns structured diagnostics:

- `VellumError.strictValidationFailed([VellumDiagnostic])`

Each `VellumDiagnostic` includes:

- `code`
- `severity`
- `specRule`
- `filePath`
- `message`
- `hint`

If you want diagnostics without throwing, use `EPUBValidator`.

## Unsupported (Current)

- DRM or encrypted EPUBs
- Reader UI rendering
- Full fixed-layout and media overlay playback semantics

## Validation Highlights

- Ensures `mimetype` ordering/compression constraints
- Validates manifest/spine referential integrity
- Requires local manifest resources to exist in the archive
- Restricts spine items to XHTML content documents
- Verifies TOC targets resolve to manifest resources
- Enforces well-formed XML for nav/NCX/content docs
- Requires a valid `epub:type="toc"` nav section when nav.xhtml is present
- Rejects unsafe resource paths (absolute/traversal) in container and manifest
- Validates `package@version` and `unique-identifier` OPF integrity
- Validates media-overlay references and cover-image manifest uniqueness

## Development

Run tests:

```bash
swift test
```

Run CLI:

```bash
swift run vellum-cli sample /tmp/sample.epub
swift run vellum-cli validate /tmp/sample.epub
swift run vellum-cli parse /tmp/sample.epub /tmp/sample.md
```
