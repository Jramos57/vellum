# Parsing EPUBs

Parse EPUB files into typed Swift models.

## Parse

```swift
import Foundation
import vellum

let url = URL(fileURLWithPath: "/tmp/book.epub")
let book = try EPUBParser().parseEPUB(at: url)
```

## Access parsed content

```swift
print(book.metadata.title)
print(book.chapters.count)
print(book.toc.map(\.label))
```

## Export text

```swift
let markdown = book.renderStructuredMarkdown()
let plainText = book.renderPlainText()
```

## Async variant

```swift
let asyncBook = try await EPUBParser().parseEPUB(at: url)
```
