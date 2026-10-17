import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Split writes one file per segment into a directory, named `base-NN.pdf` with a zero-padded
/// index whose width grows with the part count. Tests pin the naming, ordering, per-part content,
/// the empty-segment carve-out, overwrite behavior, and the failure paths.
@Suite struct PDFToolkitSplitTests {

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    @Test func writesOnePaddedFilePerSegmentInOrder() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 6, to: src)

        let outputs = try PDFToolkit.split(
            inputURL: src, into: dir.url, baseName: "part",
            segments: [[0, 1], [2, 3], [4, 5]]
        )

        // Three parts → the index stays two digits (min width), in segment order.
        #expect(names(outputs) == ["part-01.pdf", "part-02.pdf", "part-03.pdf"])
        for url in outputs { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func indexWidthGrowsWithThePartCount() throws {
        // 100 single-page parts push the padded index to three digits (part-001 … part-100).
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 100, to: src)

        let outputs = try PDFToolkit.split(
            inputURL: src, into: dir.url, baseName: "part",
            segments: (0..<100).map { [$0] }
        )

        #expect(outputs.count == 100)
        #expect(outputs.first?.lastPathComponent == "part-001.pdf")
        #expect(outputs.last?.lastPathComponent == "part-100.pdf")
    }

    @Test func eachPartContainsExactlyItsPages() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        let outputs = try PDFToolkit.split(
            inputURL: src, into: dir.url, baseName: "part",
            segments: [[0, 2], [1]]
        )

        let first = try PDFFixtures.pageTexts(at: outputs[0])
        #expect(first.count == 2)
        #expect(first[0].contains("P1"))
        #expect(first[1].contains("P3"))

        let second = try PDFFixtures.pageTexts(at: outputs[1])
        #expect(second.count == 1)
        #expect(second[0].contains("P2"))
    }

    @Test func emptySegmentsAreSkippedButStillConsumeAnIndex() throws {
        // An empty middle segment produces no file, yet the surrounding parts keep their original
        // 1-based index — so a gap (part-01, part-03) is the documented, intentional result.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        let outputs = try PDFToolkit.split(
            inputURL: src, into: dir.url, baseName: "part",
            segments: [[0], [], [1]]
        )

        #expect(names(outputs) == ["part-01.pdf", "part-03.pdf"])
    }

    @Test func overwritesAPreexistingPartFile() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["FRESH"], to: src)
        // A stale, non-PDF file already occupies the first part's name.
        try Data("junk".utf8).write(to: dir.url("part-01.pdf"))

        let outputs = try PDFToolkit.split(
            inputURL: src, into: dir.url, baseName: "part", segments: [[0]]
        )

        let texts = try PDFFixtures.pageTexts(at: outputs[0])
        #expect(texts[0].contains("FRESH"))
    }

    @Test func noSegmentsThrowsNoPagesSelected() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "part", segments: [])
        }?.kind == "noPagesSelected")
    }

    @Test func onlyEmptySegmentsThrowsNoPagesSelected() throws {
        // Segments present but all empty → nothing is written → noPagesSelected, not a silent success.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "part", segments: [[], []])
        }?.kind == "noPagesSelected")
    }

    @Test func outOfBoundsPageIndexThrows() throws {
        // Split re-checks bounds itself (segments can be handed in directly, bypassing the parser).
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "part", segments: [[5]])
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let src = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "part", segments: [[0]])
        }?.kind == "couldNotOpen")
    }

    @Test func splitNumbersAroundAnExistingFileInsteadOfOverwriting() throws {
        // The Files settings promise "a name clash is numbered, never overwritten" — Split was the
        // one tool that violated it, silently destroying any sibling named like one of its parts.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        let precious = dir.url("src-01.pdf")
        try PDFFixtures.writePDF(markers: ["PRECIOUS"], to: precious)
        let preciousBytes = try Data(contentsOf: precious)

        let outputs = try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "src", segments: [[0], [1]])

        #expect(try Data(contentsOf: precious) == preciousBytes)
        #expect(outputs.map(\.lastPathComponent) == ["src-01 2.pdf", "src-02.pdf"])
        #expect(try PDFFixtures.pageTexts(at: outputs[0]) == [PDFFixtures.marker(1)])
        #expect(try PDFFixtures.pageTexts(at: outputs[1]) == [PDFFixtures.marker(2)])
    }

    @Test func aFailingLaterSegmentUnwindsThePartsAlreadyWritten() throws {
        // Part 1 succeeds, part 2 references a page far out of bounds. The split must throw AND
        // remove the part it already wrote — a failed split leaving a half set behind reads as a
        // successful (but wrong) result in the destination folder.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        let error = #expect(throws: PDFOperationError.self) {
            _ = try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "src", segments: [[0], [99]])
        }
        #expect(error?.kind == "pageOutOfBounds")
        #expect(!FileManager.default.fileExists(atPath: dir.path("src-01.pdf")))
    }

    @Test func splitDropsSourceOutlineFromEveryPart() throws {
        // Each part is a DIFFERENT subset of the source's pages, so split deliberately drops the source
        // outline rather than reattaching it verbatim — a verbatim reattach would keep the source page
        // indices and misdirect every part's bookmarks. Given a bookmarked source, every produced part
        // must carry NO outline. This guard fails loudly if a naive reattach is ever added.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 4, bookmarks: [("A", 0), ("B", 1), ("C", 3)], to: src)

        let outputs = try PDFToolkit.split(
            inputURL: src, into: dir.url, baseName: "part",
            segments: [[0, 1], [2, 3]]
        )

        #expect(outputs.count == 2)
        for url in outputs {
            #expect(try #require(PDFDocument(url: url)).outlineRoot == nil)
            #expect(try PDFFixtures.outlineBookmarks(at: url).isEmpty)
        }
    }
}
