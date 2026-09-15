import Foundation
import Testing
@testable import vellum

@Test func publicationConvenienceAPIsResolveReadingOrderAndResources() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 3)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-publication-convenience-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: epubURL) }

    try creator.createEPUB(request, outputURL: epubURL)
    let publication = try service.open(url: epubURL).publication

    #expect(publication.readingOrderItem(id: "chapter-2")?.href == "chapter2.xhtml")
    #expect(publication.readingOrderItem(href: "chapter2.xhtml#frag")?.id == "chapter-2")
    #expect(publication.readingOrderIndex(forHref: "chapter2.xhtml") == 1)
    #expect(publication.previousReadingOrderItem(beforeHref: "chapter2.xhtml")?.id == "chapter-1")
    #expect(publication.nextReadingOrderItem(afterHref: "chapter2.xhtml")?.id == "chapter-3")
    #expect(publication.resource(id: "chapter-1")?.mediaType == "application/xhtml+xml")
    #expect(publication.resource(href: "chapter1.xhtml#p1")?.id == "chapter-1")
}

@Test func publicationConvenienceProgressUsesReadingOrderPosition() throws {
    let creator = EPUBCreator()
    let service = EPUBPublicationService()
    let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 4)
    let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-publication-progress-\(UUID().uuidString).epub")
    defer { try? FileManager.default.removeItem(at: epubURL) }

    try creator.createEPUB(request, outputURL: epubURL)
    let publication = try service.open(url: epubURL).publication

    #expect(publication.progress(forHref: "chapter1.xhtml") == 0.25)
    #expect(publication.progress(forHref: "chapter4.xhtml") == 1.0)
    #expect(publication.progress(forHref: "missing.xhtml") == nil)
}
