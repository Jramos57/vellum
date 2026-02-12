# Strict Validation

`vellum` runs in strict mode and fails fast on structural/spec issues.

## Error model

All strict failures surface as:

- `VellumError.strictValidationFailed([VellumDiagnostic])`

Unsupported features surface as:

- `VellumError.unsupportedFeature(...)`

I/O and tool failures surface as:

- `VellumError.ioFailure(...)`

## Diagnostic fields

Each `VellumDiagnostic` includes:

- `code`: stable identifier
- `severity`: `.error` or `.warning`
- `specRule`: reference label
- `filePath`: related EPUB path if available
- `message`: human-readable issue
- `hint`: concrete remediation guidance

## Example

```swift
do {
    _ = try EPUBParser().parseEPUB(at: fileURL)
} catch let VellumError.strictValidationFailed(diagnostics) {
    for d in diagnostics {
        print("[\(d.code)] \(d.message) -> \(d.hint)")
    }
}
```
