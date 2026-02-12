import Foundation

public struct MarkdownChapterLoader: Sendable {
    public init() {}

    public func loadChapters(from directoryURL: URL) throws -> [EPUBChapterInput] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else {
            throw VellumError.ioFailure("Markdown directory does not exist: \(directoryURL.path)")
        }

        let files = try fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "md" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !files.isEmpty else {
            throw VellumError.strictValidationFailed([
                .init(
                    code: "MD001",
                    specRule: "Vellum Markdown Input",
                    filePath: directoryURL.path,
                    message: "No .md chapter files found.",
                    hint: "Add one or more markdown files to the source directory."
                )
            ])
        }

        return try files.enumerated().map { idx, fileURL in
            let markdown = try String(contentsOf: fileURL, encoding: .utf8)
            let base = fileURL.deletingPathExtension().lastPathComponent
            let title = titleFromMarkdown(markdown) ?? prettifyTitle(base)
            let chapterID = "chapter-\(idx + 1)"
            let chapterFile = "chapter\(idx + 1).xhtml"
            return EPUBChapterInput(id: chapterID, title: title, markdown: markdown, fileName: chapterFile)
        }
    }

    private func titleFromMarkdown(_ markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("# ") {
                return String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func prettifyTitle(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

public extension EPUBCreator {
    func createEPUB(
        metadata: EPUBMetadata,
        markdownDirectory: URL,
        outputURL: URL,
        includeLegacyNCX: Bool = true,
        addFeatureDemoContent: Bool = false
    ) throws {
        let chapters = try MarkdownChapterLoader().loadChapters(from: markdownDirectory)
        let request = CreateRequest(
            metadata: metadata,
            chapters: chapters,
            assets: [],
            includeLegacyNCX: includeLegacyNCX,
            addFeatureDemoContent: addFeatureDemoContent
        )
        try createEPUB(request, outputURL: outputURL)
    }

    func createEPUB(
        metadata: EPUBMetadata,
        markdownDirectory: URL,
        outputURL: URL,
        includeLegacyNCX: Bool = true,
        addFeatureDemoContent: Bool = false
    ) async throws {
        let chapters = try MarkdownChapterLoader().loadChapters(from: markdownDirectory)
        let request = CreateRequest(
            metadata: metadata,
            chapters: chapters,
            assets: [],
            includeLegacyNCX: includeLegacyNCX,
            addFeatureDemoContent: addFeatureDemoContent
        )
        try await createEPUB(request, outputURL: outputURL)
    }
}
