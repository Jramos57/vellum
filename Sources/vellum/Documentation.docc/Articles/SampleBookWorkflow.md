# Sample Book Workflow

Generate and validate a 10-chapter lorem ipsum EPUB.

## Generate request

```swift
import Foundation
import vellum

let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 10)
```

## Create EPUB

```swift
let outputURL = URL(fileURLWithPath: "/tmp/vellum-lorem.epub")
try EPUBCreator().createEPUB(request, outputURL: outputURL)
```

## Parse and inspect

```swift
let book = try EPUBParser().parseEPUB(at: outputURL)
print(book.chapters.count) // 10
print(book.metadata.title)
```

## Export markdown for app ingestion

```swift
let structured = book.renderStructuredMarkdown()
```

The sample includes common EPUB manifest media references and navigation documents for integration testing.
