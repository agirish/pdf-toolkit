import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Merge concatenates whole PDFs in list order. The engine moves pages out of each freshly-loaded
/// source document, so the tests pin order, page totals, per-page content, and the open/empty
/// failure paths on real files.
@Suite struct PDFToolkitMergeTests {

    @Test func concatenatesInListOrderAndSumsPages() throws {
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ALPHA", "BETA"], to: a)
        try PDFFixtures.writePDF(markers: ["GAMMA"], to: b)

        try PDFToolkit.merge(inputURLs: [a, b], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 3)
        #expect(texts[0].contains("ALPHA"))
        #expect(texts[1].contains("BETA"))
        #expect(texts[2].contains("GAMMA"))
    }

    @Test func orderFollowsTheInputArrayNotDisk() throws {
        // Reversing the input array reverses the merged page order — order is caller-controlled.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ALPHA"], to: a)
        try PDFFixtures.writePDF(markers: ["GAMMA"], to: b)

        try PDFToolkit.merge(inputURLs: [b, a], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains("GAMMA"))
        #expect(texts[1].contains("ALPHA"))
    }

    @Test func singleFileIsCopiedWholesale() throws {
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: a)
        try PDFToolkit.merge(inputURLs: [a], outputURL: out)
        #expect(try PDFFixtures.pageCount(at: out) == 3)
    }

    @Test func sameFileTwiceDuplicatesItsPages() throws {
        // Each list entry is loaded independently, so listing a file twice legitimately doubles it.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONE", "TWO"], to: a)

        try PDFToolkit.merge(inputURLs: [a, a], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 4)
        #expect(texts[0].contains("ONE"))
        #expect(texts[3].contains("TWO"))
    }

    @Test func emptyInputListThrowsNoInputFiles() {
        let dir = FixtureDir()
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.merge(inputURLs: [], outputURL: dir.url("out.pdf"))
        }?.kind == "noInputFiles")
    }

    @Test func corruptInputThrowsCouldNotOpenNamingTheFile() throws {
        let dir = FixtureDir()
        let good = dir.url("good.pdf"), bad = dir.url("bad.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: good)
        try PDFFixtures.writeCorrupt(to: bad)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.merge(inputURLs: [good, bad], outputURL: out)
        }
        if case .couldNotOpen(let url)? = error { #expect(url == bad) } else {
            Issue.record("expected couldNotOpen(bad), got \(String(describing: error))")
        }
        // A failed merge leaves no output file behind.
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - Per-file page selection (merge(inputs:))

    @Test func perFileSelectionKeepsChosenPagesInFileOrder() throws {
        // A: keep pages 1,3,5 of 5; B: keep page 2 of 3. Output = A1, A3, A5, B2.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["A1", "A2", "A3", "A4", "A5"], to: a)
        try PDFFixtures.writePDF(markers: ["B1", "B2", "B3"], to: b)

        try PDFToolkit.merge(inputs: [(a, [0, 2, 4]), (b, [1])], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 4)
        #expect(texts[0].contains("A1"))
        #expect(texts[1].contains("A3"))
        #expect(texts[2].contains("A5"))
        #expect(texts[3].contains("B2"))
    }

    @Test func nilSelectionMeansEveryPageOfThatFile() throws {
        // nil = whole file; mix a whole file with a subset of another.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["A1", "A2"], to: a)
        try PDFFixtures.writePDF(markers: ["B1", "B2", "B3"], to: b)

        try PDFToolkit.merge(inputs: [(a, nil), (b, [2])], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 3)
        #expect(texts[0].contains("A1"))
        #expect(texts[1].contains("A2"))
        #expect(texts[2].contains("B3"))
    }

    @Test func perFileSelectionHonorsTypedOrderWithinAFile() throws {
        // Order inside a file's selection is preserved (5,1,2-style), matching Extract.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: a)

        try PDFToolkit.merge(inputs: [(a, [2, 0])], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 2)
        #expect(texts[0].contains("P3"))
        #expect(texts[1].contains("P1"))
    }

    @Test func emptySelectionContributesNoPagesFromThatFile() throws {
        // A file with an empty selection is skipped; the others still merge.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["A1", "A2"], to: a)
        try PDFFixtures.writePDF(markers: ["B1"], to: b)

        try PDFToolkit.merge(inputs: [(a, []), (b, nil)], outputURL: out)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 1)
        #expect(texts[0].contains("B1"))
    }

    @Test func selectingNoPagesAnywhereThrowsNoPagesSelected() throws {
        // Every file empty ⇒ a zero-page result, which PDFKit can't persist — refuse it up front.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["A1"], to: a)
        try PDFFixtures.writePDF(markers: ["B1"], to: b)

        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.merge(inputs: [(a, []), (b, [])], outputURL: out)
        }?.kind == "noPagesSelected")
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func outOfBoundsSelectionThrowsPageOutOfBounds() throws {
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["A1", "A2"], to: a)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.merge(inputs: [(a, [5])], outputURL: out)
        }
        #expect(error?.kind == "pageOutOfBounds")
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func perFileSelectionRefusesALockedInput() throws {
        // The per-file selection overload (the one the Merge tool actually calls) must refuse a
        // password-locked input up front, exactly like the whole-file `merge(inputURLs:)` path —
        // copying a locked page yields a blank placeholder, so a silent merge of nothing is the worst
        // outcome. The encrypted-input suite pins `merge(inputURLs:)`; this pins `merge(inputs:)`.
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf"), locked = dir.url("locked.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["A1", "A2"], to: plain)
        try PDFToolkit.encrypt(inputURL: plain, outputURL: locked, password: "secret")

        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.merge(inputs: [(plain, [0]), (locked, nil)], outputURL: out)
        }?.kind == "encryptedInput")
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func emptyInputsListThrowsNoInputFiles() {
        let dir = FixtureDir()
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.merge(inputs: [], outputURL: dir.url("out.pdf"))
        }?.kind == "noInputFiles")
    }

    // MARK: - Outline handling

    @Test func mergeDropsSourceOutlineRatherThanMisdirectIt() throws {
        // Merge concatenates pages from possibly many documents at shifting page offsets, so it
        // deliberately does NOT carry any source outline across: a naive `outlineRoot =
        // source.outlineRoot` would leave the merged file's bookmarks pointing at the wrong pages (or
        // off the end). Given a bookmarked source, the merged output must therefore carry NO outline.
        // This guard fails loudly the moment someone adds a well-meaning-but-wrong reattach.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, bookmarks: [("A", 0), ("B", 2)], to: a)
        try PDFFixtures.writePDF(pageCount: 2, to: b)

        try PDFToolkit.merge(inputURLs: [a, b], outputURL: out)

        #expect(try #require(PDFDocument(url: out)).outlineRoot == nil)
        #expect(try PDFFixtures.outlineBookmarks(at: out).isEmpty)
    }
}
