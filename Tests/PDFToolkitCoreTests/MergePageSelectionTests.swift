import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// The per-file merge feature has two halves: `MergePageSelection.resolve` turns a row's range text
/// (plus inline-dropped pages) into the index selection the engine takes, and `PDFToolkit.merge(inputs:)`
/// copies exactly those pages. These pin the resolver in isolation, then run the whole chain
/// (range text → resolved plan → merged file) on real bytes to prove page identity and order.
@Suite struct MergePageSelectionTests {

    // MARK: - resolve

    @Test func blankRangeWithNoDropsMeansWholeFile() throws {
        // nil tells the engine to copy every page at write time — the original whole-file behavior.
        #expect(try MergePageSelection.resolve(rangeText: "", dropped: [], pageCount: 5) == nil)
        #expect(try MergePageSelection.resolve(rangeText: "   ", dropped: [], pageCount: 5) == nil)
    }

    @Test func blankRangeWithDropsResolvesToAllMinusDropped() throws {
        // A dropped page on an otherwise-whole file forces an explicit selection.
        let indices = try MergePageSelection.resolve(rangeText: "", dropped: [2], pageCount: 5)
        #expect(indices == [0, 1, 3, 4])
    }

    @Test func rangeParsesToZeroBasedIndices() throws {
        // "1-3, 5" (1-based) → pages 0,1,2,4.
        let indices = try MergePageSelection.resolve(rangeText: "1-3, 5", dropped: [], pageCount: 12)
        #expect(indices == [0, 1, 2, 4])
    }

    @Test func rangeKeepsTypedOrder() throws {
        // Order is preserved like Extract: "5,1,2" → 4,0,1.
        let indices = try MergePageSelection.resolve(rangeText: "5,1,2", dropped: [], pageCount: 5)
        #expect(indices == [4, 0, 1])
    }

    @Test func droppedPagesAreRemovedFromARange() throws {
        // Range 1-5 with page 3 (index 2) dropped inline → 0,1,3,4.
        let indices = try MergePageSelection.resolve(rangeText: "1-5", dropped: [2], pageCount: 5)
        #expect(indices == [0, 1, 3, 4])
    }

    @Test func everyPageDroppedResolvesToEmpty() throws {
        // A file whose every selected page was dropped contributes nothing (empty, not nil).
        let indices = try MergePageSelection.resolve(rangeText: "1-2", dropped: [0, 1], pageCount: 5)
        #expect(indices == [])
    }

    @Test func retypingARangeReincludesAPreviouslyDroppedPage() throws {
        // Bug #1: `resolve` applies drops AFTER parsing the range, so a page dropped inline stays
        // suppressed even once the user types a range that names it. The view fixes this by clearing a
        // row's drops when its range text changes (MergeToolView's `.onChange(of: rangeText)`). This
        // pins the resolver contract that fix relies on.
        //
        // Page 3 (index 2) was dropped on the whole file — the old selection correctly omits it:
        #expect(try MergePageSelection.resolve(rangeText: "", dropped: [2], pageCount: 5) == [0, 1, 3, 4])
        // If that drop survived a retype to "3-5", page 3 would still be gone — the bug:
        #expect(try MergePageSelection.resolve(rangeText: "3-5", dropped: [2], pageCount: 5) == [3, 4])
        // With the drop cleared on the range edit, the retyped range re-includes page 3 (index 2):
        #expect(try MergePageSelection.resolve(rangeText: "3-5", dropped: [], pageCount: 5) == [2, 3, 4])
    }

    @Test func unparseableRangeThrowsInvalidPageRange() {
        #expect(#expect(throws: PDFOperationError.self) {
            try MergePageSelection.resolve(rangeText: "abc", dropped: [], pageCount: 5)
        }?.kind == "invalidPageRange")
    }

    @Test func outOfBoundsRangeThrowsPageOutOfBounds() {
        #expect(#expect(throws: PDFOperationError.self) {
            try MergePageSelection.resolve(rangeText: "9", dropped: [], pageCount: 5)
        }?.kind == "pageOutOfBounds")
    }

    // MARK: - End to end (range text → merged bytes)

    @Test func twoFilesWithRangesMergeToExactlyTheRightPagesInOrder() throws {
        // The design-review example: "1-3, 5" from A and "2, 8-10" from B, combined in file order,
        // honoring the within-range order typed. Verified on the real output's per-page text.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: (1...12).map { "A\($0)" }, to: a)
        try PDFFixtures.writePDF(markers: (1...12).map { "B\($0)" }, to: b)

        let plans: [(url: URL, pageIndices: [Int]?)] = [
            (a, try MergePageSelection.resolve(rangeText: "1-3, 5", dropped: [], pageCount: 12)),
            (b, try MergePageSelection.resolve(rangeText: "2, 8-10", dropped: [], pageCount: 12)),
        ]
        try PDFToolkit.merge(inputs: plans, outputURL: out)

        let got = try PDFFixtures.pageTexts(at: out).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(got == ["A1", "A2", "A3", "A5", "B2", "B8", "B9", "B10"])
    }

    @Test func inlineDropRemovesJustThatPageFromTheMergedFile() throws {
        // File A whole (blank range) but with a junk page 2 dropped; file B whole. Output drops only A2.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["A1", "A2", "A3"], to: a)
        try PDFFixtures.writePDF(markers: ["B1", "B2"], to: b)

        let plans: [(url: URL, pageIndices: [Int]?)] = [
            (a, try MergePageSelection.resolve(rangeText: "", dropped: [1], pageCount: 3)),
            (b, try MergePageSelection.resolve(rangeText: "", dropped: [], pageCount: 2)),
        ]
        try PDFToolkit.merge(inputs: plans, outputURL: out)

        let got = try PDFFixtures.pageTexts(at: out).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(got == ["A1", "A3", "B1", "B2"])
    }
}
