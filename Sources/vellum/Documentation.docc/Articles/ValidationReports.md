# Validation Reports

Use `EPUBValidator` when you want diagnostics without manual error switching.

## Validate

```swift
import Foundation
import vellum

let url = URL(fileURLWithPath: "/tmp/book.epub")
let report = EPUBValidator().validateEPUB(at: url)

if report.isValid {
    print("Valid EPUB")
} else {
    for diagnostic in report.diagnostics {
        print("[\(diagnostic.code)] \(diagnostic.message)")
        print("Fix: \(diagnostic.hint)")
    }
}
```

## Async variant

```swift
let report = await EPUBValidator().validateEPUB(at: url)
```
