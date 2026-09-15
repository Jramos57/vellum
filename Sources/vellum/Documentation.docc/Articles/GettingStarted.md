# Getting Started

`vellum` is a strict EPUB processing library for Apple platforms.

Use this sequence to integrate quickly:

1. Parse and inspect an EPUB.
2. Open app-facing publication DTOs.
3. Edit and save back to EPUB.

## 1. Parse Strictly

```swift
import Foundation
import vellum

let parser = EPUBParser()
let book = try parser.parseEPUB(at: sourceURL)
print(book.metadata.title)
```

## 2. Open App-Facing Data

```swift
import Foundation
import vellum

let service = EPUBPublicationService()
let opened = try service.open(url: sourceURL)
let publication = opened.publication
let first = publication.readingOrder.first
let progress = first.flatMap { publication.progress(forHref: $0.href) }
let coverURL = publication.coverResource.flatMap { opened.resources.fileURL(forHref: $0.href) }
```

## 3. Edit and Save

```swift
import Foundation
import vellum

let service = EPUBPublicationService()
let editor = EPUBPublicationEditor()

var editable = try service.openEditable(url: sourceURL)
editable = try editor.apply(
    .updateMetadata(
        EPUBMetadata(
            identifier: editable.metadata.identifier,
            title: "Updated Title",
            creator: editable.metadata.creator,
            language: editable.metadata.language,
            modified: Date(),
            publisher: editable.metadata.publisher,
            description: editable.metadata.description,
            rights: editable.metadata.rights
        )
    ),
    to: editable
)

try service.save(editable, to: outputURL)
```

## Next Steps

- Use <doc:AppIntegrationAndEditing> for full app integration details.
- Use <doc:StrictValidation> for diagnostic behavior and policy.
