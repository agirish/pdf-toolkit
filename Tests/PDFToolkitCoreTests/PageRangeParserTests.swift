import Testing
import Foundation
@testable import PDFToolkitCore

/// The page-range grammar shared by Extract, Rotate, Delete, and Split. Three parse modes with
/// deliberately different semantics — unique-sorted (a set), order-preserving (Extract), and
/// per-group segments (Split) — so each mode is pinned independently, including the edge cases
/// that separate them (reversed ranges, duplicates, empty input, out-of-bounds numbering).
@Suite struct PageRangeParserTests {

    // MARK: - Unique / sorted (Rotate range, Delete)

    @Test func parsesMixedListIntoZeroBasedSortedIndices() {
        // "1, 3-5, 8" (1-based) → the union of those pages as sorted zero-based indices.
        #expect(try! PageRangeParser.parse("1, 3-5, 8", pageCount: 10) == [0, 2, 3, 4, 7])
    }

    @Test func uniqueModeDeduplicatesAndSorts() {
        // Order typed and repeats don't matter here — the result is a sorted set.
        #expect(try! PageRangeParser.parse("3,1,2,2,1", pageCount: 5) == [0, 1, 2])
    }

    @Test func uniqueModeCollapsesAReversedRangeToASortedSet() {
        // "5-3" and "3-5" mean the same set of pages for rotate/delete, where order is irrelevant.
        #expect(try! PageRangeParser.parse("5-3", pageCount: 5) == [2, 3, 4])
        #expect(try! PageRangeParser.parse("3-5", pageCount: 5) == [2, 3, 4])
    }

    @Test func toleratesWhitespaceAroundNumbersAndDashes() {
        #expect(try! PageRangeParser.parse("  1 , 3 - 4 ", pageCount: 10) == [0, 2, 3])
    }

    @Test func skipsEmptyGroupsFromStrayCommas() {
        // Trailing and doubled commas produce empty groups, which are ignored rather than erroring.
        #expect(try! PageRangeParser.parse("1,,3,", pageCount: 5) == [0, 2])
    }

    // MARK: Empty-input policy

    @Test func emptyMeansAllPagesWhenAllowed() {
        // Extract / Rotate: a blank field selects every page.
        #expect(try! PageRangeParser.parse("", pageCount: 3) == [0, 1, 2])
        #expect(try! PageRangeParser.parse("   ", pageCount: 3) == [0, 1, 2])
    }

    @Test func emptyThrowsWhenAllPagesNotAllowed() {
        // Delete: a blank field must NOT silently mean "delete everything".
        let error = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("", pageCount: 3, emptyMeansAllPages: false)
        }
        #expect(error?.kind == "pageRangeRequired")
    }

    // MARK: Out-of-bounds / malformed (unique mode)

    @Test func rejectsPageAboveTheDocument() {
        // The offending 1-based number is reported, not its zero-based index.
        let error = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("11", pageCount: 10)
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 11) } else {
            Issue.record("expected pageOutOfBounds(11), got \(String(describing: error))")
        }
    }

    @Test func rejectsRangeThatSpillsPastTheEnd() {
        // "9-12" over 10 pages fails at the first out-of-range page (11).
        let error = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("9-12", pageCount: 10)
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 11) } else {
            Issue.record("expected pageOutOfBounds(11), got \(String(describing: error))")
        }
    }

    @Test func rejectsPageZeroAsOutOfBounds() {
        // Pages are 1-based; "0" maps to index -1, which is out of the document.
        let error = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("0", pageCount: 5)
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 0) } else {
            Issue.record("expected pageOutOfBounds(0), got \(String(describing: error))")
        }
    }

    @Test func rejectsNonNumericTokens() {
        let error = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("1, x, 3", pageCount: 5)
        }
        if case .invalidPageRange(let s)? = error { #expect(s == "x") } else {
            Issue.record("expected invalidPageRange(\"x\"), got \(String(describing: error))")
        }
    }

    @Test func rejectsHalfOpenRangeAsInvalid() {
        // "3-" splits to a single token (empty side dropped), so it can't form a range.
        #expect(#expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("3-", pageCount: 5)
        }?.kind == "invalidPageRange")
    }

    @Test func rejectsInputThatReducesToNoPages() {
        // Only separators → nothing selected → invalidPageRange (not an empty success).
        #expect(#expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse(",,", pageCount: 5)
        }?.kind == "invalidPageRange")
    }

    // MARK: - Order preserved (Extract)

    @Test func preserveOrderKeepsTypedSequence() {
        // "5,1,2" must extract page 5 first, then 1, then 2 — order is the whole point of Extract.
        #expect(try! PageRangeParser.parse("5,1,2", pageCount: 5, preserveOrder: true) == [4, 0, 1])
    }

    @Test func preserveOrderExpandsAscendingRangeUpward() {
        #expect(try! PageRangeParser.parse("3-5", pageCount: 5, preserveOrder: true) == [2, 3, 4])
    }

    @Test func preserveOrderExpandsDescendingRangeDownward() {
        // Unlike unique mode, "5-3" here yields 5,4,3 in that order — Extract honors direction.
        #expect(try! PageRangeParser.parse("5-3", pageCount: 5, preserveOrder: true) == [4, 3, 2])
    }

    @Test func preserveOrderAllowsDuplicatePages() {
        // Listing a page twice legitimately duplicates it in the output.
        #expect(try! PageRangeParser.parse("1,1,2", pageCount: 5, preserveOrder: true) == [0, 0, 1])
    }

    @Test func preserveOrderCombinesDirectionalRangeAndSingles() {
        #expect(try! PageRangeParser.parse("5-3, 1", pageCount: 5, preserveOrder: true) == [4, 3, 2, 0])
    }

    @Test func preserveOrderEmptyStillMeansAllPages() {
        // The empty-input policy is applied before the order branch.
        #expect(try! PageRangeParser.parse("", pageCount: 3, preserveOrder: true) == [0, 1, 2])
    }

    @Test func preserveOrderThrowsOnAstronomicalRangeWithoutAllocating() {
        // "1-999999999" is one extra digit away from a real range. The order-preserving branch
        // used to materialize the whole span into an Array before any bounds check — gigabytes
        // for a typo. It must instead throw at the first out-of-bounds page, instantly. (If this
        // regresses, the test doesn't fail so much as the suite OOMs — either way, loudly.)
        let ascending = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("1-999999999", pageCount: 3, preserveOrder: true)
        }
        if case .pageOutOfBounds(let page) = ascending { #expect(page == 4) }

        let descending = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("999999999-1", pageCount: 3, preserveOrder: true)
        }
        if case .pageOutOfBounds(let page) = descending { #expect(page == 999_999_999) }
    }

    @Test func preserveOrderRejectsOutOfBoundsRange() {
        let error = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parse("2-4", pageCount: 3, preserveOrder: true)
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 4) } else {
            Issue.record("expected pageOutOfBounds(4), got \(String(describing: error))")
        }
    }

    // MARK: - Segments (Split — one array per comma group)

    @Test func segmentsGroupEachCommaPartSeparately() {
        // "1-3, 4-6, 7" → three output files: a 3-page, a 3-page, and a 1-page.
        #expect(try! PageRangeParser.parseSegments("1-3, 4-6, 7", pageCount: 7)
            == [[0, 1, 2], [3, 4, 5], [6]])
    }

    @Test func segmentsSinglePagesEachBecomeTheirOwnGroup() {
        #expect(try! PageRangeParser.parseSegments("1,2,3", pageCount: 3) == [[0], [1], [2]])
    }

    @Test func segmentsNormalizeAReversedRangeAscending() {
        // A split group is a contiguous slice, so "3-1" is the same file as "1-3" (ascending).
        #expect(try! PageRangeParser.parseSegments("3-1", pageCount: 5) == [[0, 1, 2]])
    }

    @Test func segmentsTolerateWhitespace() {
        #expect(try! PageRangeParser.parseSegments(" 1 - 2 , 4 ", pageCount: 5) == [[0, 1], [3]])
    }

    @Test func segmentsRejectEmptyInput() {
        #expect(#expect(throws: PDFOperationError.self) {
            try PageRangeParser.parseSegments("", pageCount: 5)
        }?.kind == "pageRangeRequired")
    }

    @Test func segmentsRejectOutOfBoundsRange() {
        let error = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parseSegments("1-10", pageCount: 5)
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }

    @Test func segmentsRejectInvalidToken() {
        let error = #expect(throws: PDFOperationError.self) {
            try PageRangeParser.parseSegments("1, x", pageCount: 5)
        }
        if case .invalidPageRange(let s)? = error { #expect(s == "x") } else {
            Issue.record("expected invalidPageRange(\"x\"), got \(String(describing: error))")
        }
    }

    @Test func segmentsRejectInputThatReducesToNoGroups() {
        #expect(#expect(throws: PDFOperationError.self) {
            try PageRangeParser.parseSegments(",,", pageCount: 5)
        }?.kind == "invalidPageRange")
    }

    // MARK: - Fixed chunks (Split — "Every N pages")

    @Test func everyNEvenlyDividesIntoChunks() {
        #expect(PageRangeParser.everyNPagesSegments(pageCount: 6, chunkSize: 2)
            == [[0, 1], [2, 3], [4, 5]])
    }

    @Test func everyNLastChunkTakesTheRemainder() {
        // 5 pages by 2 → two full chunks and a one-page tail.
        #expect(PageRangeParser.everyNPagesSegments(pageCount: 5, chunkSize: 2)
            == [[0, 1], [2, 3], [4]])
    }

    @Test func everyNChunkLargerThanDocumentIsASingleFile() {
        #expect(PageRangeParser.everyNPagesSegments(pageCount: 3, chunkSize: 10) == [[0, 1, 2]])
    }

    @Test func everyNFloorsChunkSizeAtOne() {
        // A zero/negative stepper value must not produce an empty (infinite) stride.
        #expect(PageRangeParser.everyNPagesSegments(pageCount: 3, chunkSize: 0) == [[0], [1], [2]])
        #expect(PageRangeParser.everyNPagesSegments(pageCount: 3, chunkSize: -5) == [[0], [1], [2]])
    }

    @Test func everyNOnAnEmptyDocumentYieldsNoSegments() {
        #expect(PageRangeParser.everyNPagesSegments(pageCount: 0, chunkSize: 2).isEmpty)
    }

    @Test func everyNSegmentCountMatchesCeilDivision() {
        // The invariant behind the live "N files" hint: the count the preview shows is exactly the
        // number of files the split writes.
        for (pages, chunk, expected) in [(6, 2, 3), (5, 2, 3), (7, 3, 3), (1, 4, 1), (10, 1, 10)] {
            #expect(PageRangeParser.everyNPagesSegments(pageCount: pages, chunkSize: chunk).count == expected)
        }
    }
}
