import Foundation
import Testing
@testable import vellum

@Test func publicationServiceOpensFromURL() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 3)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-publication-url-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: epubURL) }

    try creator.createEPUB(request, outputURL: epubURL)
    let publication = try service.open(url: epubURL)

    #expect(publication.metadata.title == request.metadata.title)
    #expect(publication.readingOrder.count == 3)
    #expect(publication.navigation.toc.count == 3)
    #expect(publication.resources.contains(where: { $0.mediaType == "application/xhtml+xml" }))
}

@Test func publicationServiceOpensFromData() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 2)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-publication-data-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: epubURL) }

    try creator.createEPUB(request, outputURL: epubURL)
    let data = try Data(contentsOf: epubURL)
    let publication = try service.open(data: data)

    #expect(publication.readingOrder.count == 2)
    #expect(publication.navigation.pageList.count == 2)
    #expect(publication.navigation.landmarks.count == 1)
}

@Test func publicationIndexesAndLocatorResolveByNormalizedHref() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 1)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-publication-index-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: epubURL) }

    try creator.createEPUB(request, outputURL: epubURL)
    let publication = try service.open(url: epubURL)

    #expect(publication.manifestIndex["chapter-1"]?.href == "chapter1.xhtml")
    #expect(publication.hrefIndex["chapter1.xhtml"]?.id == "chapter-1")

    let locator = Locator(href: "chapter1.xhtml#p1", fragment: "p1")
    #expect(publication.readingOrderItem(for: locator)?.id == "chapter-1")
}
