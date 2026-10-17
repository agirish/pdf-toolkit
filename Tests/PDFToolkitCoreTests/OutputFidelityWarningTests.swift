import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// The warnings shown before a tool writes output that will genuinely lose something: form fields
/// flattened by a page rebuild, and bookmarks dropped by Merge/Split. Both are conditional — they
/// must appear only when the loaded file actually HAS the thing at risk, or they become wallpaper.
struct OutputFidelityWarningTests {

    private func pdfWithBookmarks(_ count: Int, in dir: FixtureDir, named name: String) throws -> URL {
        let plain = dir.url("plain-\(name)")
        try PDFFixtures.writePDF(pageCount: max(1, count), to: plain)
        let doc = try #require(PDFDocument(url: plain))
        if count > 0 {
            let root = PDFOutline()
            for i in 0..<count {
                let child = PDFOutline()
                child.label = "Bookmark \(i + 1)"
                child.destination = PDFDestination(page: try #require(doc.page(at: i)), at: .zero)
                root.insertChild(child, at: root.numberOfChildren)
            }
            doc.outlineRoot = root
        }
        let url = dir.url(name)
        try #require(doc.write(to: url))
        return url
    }

    // MARK: Bookmarks

    @Test func bookmarkCountWalksTheWholeTree() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        let doc = try #require(PDFDocument(url: plain))
        let root = PDFOutline()
        let parent = PDFOutline()
        parent.label = "Part I"
        parent.destination = PDFDestination(page: try #require(doc.page(at: 0)), at: .zero)
        let child = PDFOutline()
        child.label = "Chapter 1"
        child.destination = PDFDestination(page: try #require(doc.page(at: 1)), at: .zero)
        parent.insertChild(child, at: 0)
        root.insertChild(parent, at: 0)
        doc.outlineRoot = root
        let url = dir.url("nested.pdf")
        try #require(doc.write(to: url))

        #expect(PDFToolkit.bookmarkCount(at: url) == 2, "nested children must be counted")
    }

    @Test func noBookmarksMeansNoWarning() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: plain)
        #expect(PDFToolkit.bookmarkCount(at: plain) == 0)
        #expect(OutputFidelityWarning.detect(in: [plain], formLoss: nil, checksBookmarks: true) == nil)
    }

    @Test func bookmarkWarningTotalsAcrossOnlyTheFilesThatHaveThem() throws {
        let dir = FixtureDir()
        let a = try pdfWithBookmarks(3, in: dir, named: "a.pdf")
        let b = try pdfWithBookmarks(0, in: dir, named: "b.pdf")
        let c = try pdfWithBookmarks(2, in: dir, named: "c.pdf")

        let warning = try #require(OutputFidelityWarning.detect(in: [a, b, c], formLoss: nil, checksBookmarks: true))
        #expect(warning.losses == [.bookmarks(total: 5, fileCount: 2)])
        let detail = warning.detail(toolTitle: "Merge")
        #expect(detail.contains("2 of these files"))
        #expect(detail.contains("5 bookmarks"))
    }

    @Test func singleFileBookmarkWarningReadsNaturally() throws {
        let dir = FixtureDir()
        let a = try pdfWithBookmarks(1, in: dir, named: "a.pdf")
        let warning = try #require(OutputFidelityWarning.detect(in: [a], formLoss: nil, checksBookmarks: true))
        let detail = warning.detail(toolTitle: "Split")
        #expect(detail.contains("This PDF has 1 bookmark,"))
        #expect(!detail.contains("1 bookmarks"))
    }

    // MARK: Interactive forms

    @Test func aPlainPDFRaisesNoFormWarning() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        #expect(OutputFidelityWarning.detect(in: [plain], formLoss: .formFlattened, checksBookmarks: false) == nil)
    }

    // MARK: The acknowledgement gate

    // MARK: The click-beats-detection race
}
