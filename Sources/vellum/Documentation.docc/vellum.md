# ``vellum``

Strict Swift library for EPUB creation, parsing, and text extraction.

## Overview

`vellum` provides a processing-first EPUB toolkit for Apple platforms. It is intentionally focused on deterministic content processing, not reader UI.

You can use it to:

- Build EPUBs from markdown chapters and metadata
- Parse EPUB archives in strict mode
- Export book content as structured markdown or plain text
- Generate a 10-chapter lorem ipsum sample EPUB for integration testing

## Topics

### Creating EPUBs

- ``EPUBCreator``
- ``CreateRequest``
- ``EPUBMetadata``
- ``EPUBChapterInput``
- <doc:CreatingEPUBs>

### Parsing EPUBs

- ``EPUBParser``
- ``EPUBBook``
- ``EPUBChapter``
- ``EPUBManifestItem``
- ``EPUBSpineItem``
- ``EPUBTOCNode``
- <doc:ParsingEPUBs>

### Validation and Diagnostics

- ``VellumDiagnostic``
- ``VellumError``
- <doc:StrictValidation>

### Sample Content

- ``SampleBookFactory``
- <doc:SampleBookWorkflow>

### Exporting Text

- ``EPUBBook/renderStructuredMarkdown()``
- ``EPUBBook/renderPlainText()``

## Standards

`vellum` uses W3C EPUB specifications as normative references:

- [EPUB 3.3](https://www.w3.org/TR/epub-33/)
- [EPUB Reading Systems 3.3](https://www.w3.org/TR/epub-rs-33/)
- [EPUB Accessibility 1.1](https://www.w3.org/TR/epub-a11y-11/)

For implementation mapping, see `Documentation/STANDARDS_MAPPING.md` in the repository.
