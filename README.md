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
- Zero external dependencies: in-house ZIP archive; DEFLATE and CRC32 use the
  system's Compression framework and zlib where available (byte-identical, about
  10× faster opens) and pure Swift elsewhere, such as Linux
- Strict validation mode
- EPUB create + parse + block-aware plain-text output
- Single-extraction disk-backed resource access for app workflows
- Sample 10-chapter lorem ipsum EPUB generator
- Navigation + manifest + spine integrity validation
- EPUB2 NCX fallback parsing
- Kobo and other store EPUBs whose manifest hrefs step up a folder (`../`) while
  staying inside the package
- Optional lenient parsing for real-world books that break the spec
- The book's own CSS stylesheets, for readers that render its styling

### What's new in 0.3.0

Everything here came from shipping vellum in the Relegere reader:

- Manifest hrefs may go up within the package (`../Text/ch1.xhtml` from
  `OEBPS/package.opf`), as Kobo and other stores write them. An href is still
  rejected when either its decoded or its percent-encoded reading leaves the
  package. Before 0.3.0 these books failed to open with `PAR030`.
- `EPUBParser(mode: .lenient)` opens books with recoverable spec problems and
  reports them in `EPUBBook.diagnostics`. `.strict` (the default) throws as before.
- `EPUBBook.stylesheets` holds the package's CSS by href. `EPUBTOCNode.level`
  holds the table of contents' nesting depth.
- ZIP limits are 512 MiB per entry and 2 GiB per archive. Disk-backed resources
  never resolve outside the extracted package.
- Navigation and NCX hrefs resolve relative to their own document (subfolders,
  percent-encoding, fragments), keeping the hierarchy.
- Font obfuscation (IDPF and Adobe) and an empty `encryption.xml` are accepted;
  encrypted content documents (real DRM) are still rejected.
- In lenient mode, one bad chapter, an SVG spine item, a missing font or a
  UTF-16 chapter no longer makes the whole book unreadable: defects become
  diagnostics.

All changes are additive; code written for 0.2.0 compiles unchanged. Encoded
`EPUBBook` values from 0.2.0 still decode.

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
    .package(url: "https://github.com/Jramos57/vellum.git", from: "0.3.0")
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

### Create an EPUB from existing XHTML (formatting preserved)

Markdown chapters are converted into vellum's own template. When a book's
markup must survive (its stylesheet, classes, ids, poetry layout, pop-up
footnotes), pass each chapter as a complete XHTML document instead. It is
checked for well-formedness and written to the package byte for byte.

```swift
let chapters = [
    EPUBChapterInput(id: "c1", title: "Genesis 1", xhtml: genesis1XHTML, fileName: "c1.xhtml"),
    // Kept out of the reading order and the table of contents.
    EPUBChapterInput(id: "maps", title: "Maps", xhtml: mapsXHTML, fileName: "maps.xhtml",
                     linear: false, includeInNavigation: false),
]
let request = CreateRequest(
    metadata: EPUBMetadata(identifier: "urn:uuid:…", title: "My Bible", creator: "Publisher",
                           subjects: ["BIB016000"], source: "urn:isbn:9780310461494"),
    chapters: chapters,
    assets: [
        EPUBAsset(id: "css", relativePath: "book.css", mediaType: "text/css", data: css),
        // `cover-image` also writes the EPUB 2 <meta name="cover">.
        EPUBAsset(id: "cover", relativePath: "images/cover.jpg", mediaType: "image/jpeg",
                  data: cover, properties: ["cover-image"]),
    ],
    landmarks: [EPUBLandmark(type: "bodymatter", title: "Genesis 1", href: "c1.xhtml")],
    includeGeneratedPageList: false  // no "Page N" entries posing as print pages
)
try EPUBCreator().createEPUB(request, outputURL: URL(fileURLWithPath: "/tmp/bible.epub"))
```

Books with only XHTML chapters don't get vellum's `styles/main.css`.
The creator rejects requests that would lose or overwrite content before it
writes anything:

| Code | Problem |
|---|---|
| CRT002 | Two chapters or assets share a file name (compared case- and Unicode-insensitively, as Apple file systems do), or a name is both a file and a folder |
| CRT003 / CRT005 | A chapter or asset path is absolute, escapes the package, or has a colon in its first segment |
| CRT004 | An XHTML chapter isn't well-formed XML as written: unbalanced markup, an HTML named entity such as `&nbsp;` (EPUB 3 has no DTD; use `&#160;` or the character), or an encoding declaration other than UTF-8 |
| CRT006 | A manifest id is used twice or isn't a valid XML id (`nav`, `ncx` and `css` are reserved) |
| CRT007 | A file name collides with a generated file (`content.opf`, `nav.xhtml`, `toc.ncx`, and `styles/main.css` when a chapter is Markdown) |
| CRT008 | A landmark doesn't point at a chapter |
| CRT009 / CRT010 | No chapter is in the navigation (or a listed chapter has no title), or none is in the reading order |
| CRT011 | A chapter or asset claims `nav`, a chapter claims `cover-image`, or more than one asset is the cover |

### Build from a JSON manifest

`vellum-cli create book.json out.epub` builds the same request from a JSON
file whose chapters and assets are files next to it, so a script in any
language can prepare a book and leave packaging to vellum. See
`EPUBBuildManifest` for the format:

```json
{
  "metadata": { "identifier": "urn:uuid:…", "title": "My Bible", "creator": "Publisher",
                "language": "en-US", "subjects": ["BIB016000"] },
  "chapters": [
    { "id": "c1", "title": "Genesis 1", "fileName": "c1.xhtml", "xhtmlFile": "text/c1.xhtml" },
    { "id": "maps", "title": "Maps", "fileName": "maps.xhtml", "xhtmlFile": "text/maps.xhtml",
      "linear": false, "includeInNavigation": false }
  ],
  "assets": [
    { "id": "css", "relativePath": "book.css", "mediaType": "text/css", "file": "book.css" }
  ],
  "landmarks": [ { "type": "bodymatter", "title": "Genesis 1", "href": "c1.xhtml" } ],
  "includeGeneratedPageList": false
}
```

Parsed books report `EPUBSpineItem.linear` and `EPUBMetadata.subjects` / `source`.

## API Surface

- `EPUBCreator`
  - `createEPUB(_:outputURL:) throws`
  - `createEPUB(_:outputURL:) async throws`
  - `createEPUB(metadata:markdownDirectory:outputURL:...) throws`
  - `createEPUB(metadata:markdownDirectory:outputURL:...) async throws`
- `EPUBBuildManifest`
  - `load(from:) throws -> EPUBBuildManifest`
  - `makeRequest(relativeTo:) throws -> CreateRequest`
- `EPUBParser`
  - `init(mode:)` (`.strict` by default, or `.lenient`)
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
  - `diagnostics` (recoverable problems found in lenient mode)
  - `stylesheets` (CSS by href)
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
swift run vellum-cli create /tmp/book/book.json /tmp/book.epub
swift run vellum-cli validate /tmp/sample.epub
swift run vellum-cli parse /tmp/sample.epub /tmp/sample.md
```
