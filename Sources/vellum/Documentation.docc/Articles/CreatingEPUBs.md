# Creating EPUBs

Create a valid EPUB archive from markdown and metadata.

## Build a request

```swift
import Foundation
import vellum

let metadata = EPUBMetadata(
    identifier: "urn:uuid:\(UUID().uuidString)",
    title: "My EPUB",
    creator: "Author"
)

let chapters = [
    EPUBChapterInput(
        id: "chapter-1",
        title: "Chapter 1",
        markdown: "# Chapter 1\n\nHello world.",
        fileName: "chapter1.xhtml"
    )
]

let request = CreateRequest(
    metadata: metadata,
    chapters: chapters,
    includeLegacyNCX: true,
    addFeatureDemoContent: true
)
```

## Write archive

```swift
let outputURL = URL(fileURLWithPath: "/tmp/book.epub")
try EPUBCreator().createEPUB(request, outputURL: outputURL)
```

## Async variant

```swift
try await EPUBCreator().createEPUB(request, outputURL: outputURL)
```

## Create from markdown directory

```swift
let metadata = EPUBMetadata(
    identifier: "urn:uuid:\(UUID().uuidString)",
    title: "Folder Book",
    creator: "Author"
)

try EPUBCreator().createEPUB(
    metadata: metadata,
    markdownDirectory: URL(fileURLWithPath: "/tmp/book-md"),
    outputURL: URL(fileURLWithPath: "/tmp/book.epub")
)
```

## Notes

- `mimetype` is written first and uncompressed.
- `META-INF/container.xml`, `OEBPS/content.opf`, and `OEBPS/nav.xhtml` are generated.
- Strict checks run on created output.
