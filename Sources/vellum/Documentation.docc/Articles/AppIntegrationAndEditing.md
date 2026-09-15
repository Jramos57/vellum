# App Integration and Editing

Use `vellum` as a data engine in your app:

1. Open EPUB content into resolved, app-facing models.
2. Drive reader/list/detail views from reading order and navigation.
3. Apply edit commands to a mutable publication model.
4. Save back to EPUB and reopen for verification.

## Open for UI Data

```swift
import Foundation
import vellum

let service = EPUBPublicationService()
let opened = try service.open(url: sourceURL)
let publication = opened.publication

let first = publication.readingOrder.first
let next = first.map { publication.nextReadingOrderItem(afterHref: $0.href) }
let progress = first.flatMap { publication.progress(forHref: $0.href) }

// Resources stay on disk; read bytes on demand
let chapterData = try opened.resources.data(forHref: "chapter1.xhtml")
```

`OpenedPublication` and `Publication` expose:

- `publication.readingOrder` for canonical display order
- `publication.navigation` for TOC/landmarks/page list
- `publication.coverResource` for the resolved cover image
- `resources.fileURL(forHref:)` / `resources.data(forHref:)` for package resources
- fast id/href lookup helpers

## Edit and Save

```swift
import Foundation
import vellum

let service = EPUBPublicationService()
let editor = EPUBPublicationEditor()

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
let updated = try service.open(url: outputURL).publication
```

`EPUBPublicationEditor` validates integrity for every command application.

## Preservation Notes

- Unknown OPF metadata is preserved best-effort through `preservedMetadataEntries`.
- Save output is EPUB 3.
- Navigation can be auto-generated from chapters or overridden with `NavigationTree`.

