# Standards Mapping

This document maps `vellum` behavior to W3C EPUB standards.

## Normative References

- EPUB 3.3: https://www.w3.org/TR/epub-33/
- EPUB Reading Systems 3.3: https://www.w3.org/TR/epub-rs-33/
- EPUB Accessibility 1.1: https://www.w3.org/TR/epub-a11y-11/

## Implemented in v0.1.0

### OCF ZIP Container basics

- `mimetype` entry creation and strict checks
- `META-INF/container.xml` generation and parsing
- OPF location discovery from `container.xml`

### Package document (OPF)

- Metadata extraction:
  - identifier
  - title
  - creator
  - language
  - modified date
- Manifest extraction and integrity checks
- Spine extraction and referential checks

### Navigation

- EPUB 3 nav document generation (`nav.xhtml`)
- TOC extraction from nav links
- Optional EPUB 2 compatibility NCX generation (`toc.ncx`)

### Content and text output

- Chapter XHTML generation from markdown
- Plain text extraction from XHTML
- Structured markdown export for downstream app ingestion

## Validation Policy

Strict mode only in v0.1.0:

- Any hard validation issue throws `VellumError.strictValidationFailed`
- Diagnostics include machine-friendly codes and actionable fix hints

## Feature Coverage in Sample Book

The generated sample book includes manifest entries and assets for:

- XHTML chapters
- CSS
- JPEG
- SVG
- OpenType font
- JavaScript resource
- MP3
- MP4
- EPUB nav + landmarks + page-list + NCX

## Not Yet Fully Implemented

The EPUB specification is broad. The following are intentionally not fully implemented in v0.1.0:

- DRM decryption and rights handling
- Complete media overlays semantics
- Comprehensive fixed-layout behavior
- Full scripting policy and sandbox model
- Full a11y semantic conformance checks across all documents

These are tracked for incremental implementation.

