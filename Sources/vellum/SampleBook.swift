import Foundation

/// Factory for deterministic sample EPUB requests used in integration workflows.
public enum SampleBookFactory {
    /// Creates a lorem ipsum sample request with broad format coverage.
    ///
    /// - Parameter chapterCount: Number of generated chapters. Defaults to `10`.
    /// - Returns: A ready-to-create EPUB request.
    public static func makeLoremIpsumBook(chapterCount: Int = 10) -> CreateRequest {
        makeRequest(chapterCount: chapterCount, addFeatureDemoContent: true)
    }

    /// Creates a lorem ipsum sample request focused on broad reading-system compatibility.
    ///
    /// This profile excludes synthetic feature-demo media payloads so the output is safer for
    /// direct import in strict reader apps like Apple Books.
    ///
    /// - Parameter chapterCount: Number of generated chapters. Defaults to `10`.
    /// - Returns: A ready-to-create EPUB request.
    public static func makeReaderSafeLoremIpsumBook(chapterCount: Int = 10) -> CreateRequest {
        makeRequest(chapterCount: chapterCount, addFeatureDemoContent: false)
    }

    private static func makeRequest(chapterCount: Int, addFeatureDemoContent: Bool) -> CreateRequest {
        let metadata = EPUBMetadata(
            identifier: "urn:uuid:\(UUID().uuidString.lowercased())",
            title: "Vellum Lorem Ipsum Sample",
            creator: "Vellum",
            language: "en",
            modified: Date(),
            publisher: "Vellum Labs",
            description: "A 10-chapter EPUB sample containing broad EPUB feature coverage for validation.",
            rights: "Public Domain Sample"
        )

        let lorem = """
        Lorem ipsum dolor sit amet, consectetur adipiscing elit. Integer vulputate, velit non
        consequat feugiat, tellus nisl vulputate erat, at scelerisque arcu nibh quis magna.

        Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque
        laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis.
        """

        let chapters: [EPUBChapterInput] = (1...chapterCount).map { idx in
            EPUBChapterInput(
                id: "chapter-\(idx)",
                title: "Chapter \(idx)",
                markdown: """
                # Chapter \(idx)

                \(lorem)

                ## Section \(idx).1

                \(lorem)
                """,
                fileName: "chapter\(idx).xhtml"
            )
        }

        return CreateRequest(
            metadata: metadata,
            chapters: chapters,
            assets: [],
            includeLegacyNCX: true,
            addFeatureDemoContent: addFeatureDemoContent
        )
    }
}
