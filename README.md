# vellum

Strict Swift library for EPUB creation, parsing, and text extraction.

`vellum` is designed as a processing engine you can embed into your app pipeline before UI integration.

For app-facing integration, prefer `EPUBPublicationService` + `Publication`/`EditablePublication`.
Treat `EPUBParser` + `EPUBBook` as low-level parsing primitives for advanced workflows.

Documentation:
- [DocC Reference](https://jramos57.github.io/vellum/documentation/vellum/)

## Status

- Swift 6 package
- Apple platforms: macOS, iOS, tvOS, watchOS, visionOS
- Zero external dependencies: in-house ZIP archive and pure Swift DEFLATE/CRC32
- Strict validation mode
- EPUB create + parse + block-aware plain-text output
- Single-extraction disk-backed resource access for app workflows
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
    .package(url: "https://github.com/Jramos57/vellum.git", from: "0.1.0")
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

### App flow: open, edit, save, reopen

```swift
import Foundation
import vellum

let service = EPUBPublicationService()
let editor = EPUBPublicationEditor()

let sourceURL = URL(fileURLWithPath: "/tmp/source.epub")
let outputURL = URL(fileURLWithPath: "/tmp/edited.epub")

// Open for app view data; package resources stay on disk
let opened = try service.open(url: sourceURL)
let publication = opened.publication
let chapter = publication.readingOrder.first
let next = chapter.map { publication.nextReadingOrderItem(afterHref: $0.href) }

// Serve resources on demand without loading the whole package into memory
let coverURL = publication.coverResource.flatMap { opened.resources.fileURL(forHref: $0.href) }
let chapterData = try opened.resources.data(forHref: "chapter1.xhtml")

// Open editable model, apply command(s), and save
var editable = try service.openEditable(url: sourceURL)
editable = try editor.apply(
    .updateChapter(
        id: "chapter-1",
        xhtml: """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 1</title></head>
        <body><p>Edited in app.</p></body>
        </html>
        """,
        title: "Updated Chapter 1"
    ),
    to: editable
)

try service.save(editable, to: outputURL)

// Reopen and continue rendering in app
let updated = try service.open(url: outputURL).publication
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
- `EPUBPublicationService`
  - `open(url:) throws -> OpenedPublication`
  - `open(url:) async throws -> OpenedPublication`
  - `open(data:) throws -> OpenedPublication`
  - `open(data:) async throws -> OpenedPublication`
  - `openEditable(url:includeLegacyNCX:) throws -> EditablePublication`
  - `openEditable(data:includeLegacyNCX:) throws -> EditablePublication`
  - `save(_:to:) throws`
  - `save(_:) throws -> Data`
- `OpenedPublication`
  - `publication`
  - `resources`
- `PublicationResources`
  - `fileURL(forHref:)`
  - `data(forHref:)`
  - `contains(_:)`
  - `removeExtractedContent()`
- `EPUBPublicationEditor`
  - `makeEditable(from:includeLegacyNCX:)`
  - `apply(_:to:) throws -> EditablePublication`
- `EPUBEditCommand`
  - `updateMetadata`
  - `insertChapter`
  - `updateChapter`
  - `removeChapter`
  - `moveChapter`
  - `addAsset`
  - `removeAsset`
  - `setNavigationOverride`
- `EPUBValidator`
  - `validateEPUB(at:) -> ValidationReport`
  - `validateEPUB(at:) async -> ValidationReport`
- `SampleBookFactory`
  - `makeLoremIpsumBook(chapterCount:)`
- `EPUBBook`
  - `renderStructuredMarkdown()`
  - `renderPlainText()`
- `Publication`
  - `readingOrder`
  - `navigation`
  - `resources`
  - `manifestIndex`
  - `hrefIndex`
  - `coverResource`
  - `readingOrderItem(id:)`
  - `readingOrderItem(href:)`
  - `nextReadingOrderItem(afterHref:)`
  - `previousReadingOrderItem(beforeHref:)`
  - `resource(id:)`
  - `resource(href:)`
  - `progress(forHref:)`
- `EditablePublication`
  - `metadata`
  - `chapters`
  - `assets`
  - `preservedMetadataEntries` (best-effort unknown OPF metadata round-trip)

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

Generate DocC archive:

```bash
xcodebuild docbuild -scheme vellum -destination 'platform=macOS'
```

The generated archive is written under Xcode DerivedData as `vellum.doccarchive`.

Export static site for GitHub Pages:

```bash
xcrun docc process-archive transform-for-static-hosting \
  /Users/$USER/Library/Developer/Xcode/DerivedData/<DerivedData>/Build/Products/Debug/vellum.doccarchive \
  --output-path ./docs \
  --hosting-base-path vellum
```

Then publish `./docs` with GitHub Pages.

Run CLI:

```bash
swift run vellum-cli sample /tmp/sample.epub
swift run vellum-cli sample /tmp/sample-feature.epub --feature-demo
swift run vellum-cli validate /tmp/sample.epub
swift run vellum-cli parse /tmp/sample.epub /tmp/sample.md
```
