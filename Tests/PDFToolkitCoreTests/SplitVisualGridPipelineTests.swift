import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// End-to-end proof of Split's visual grid: it drives the *exact* composition the Run button uses —
/// derive `[[Int]]` segments from the model, then hand them to `PDFToolkit.split` — and asserts the
/// output folder holds precisely the expected files, each with precisely the expected source pages.
///
/// The visual grid, "Every N pages", and "Custom ranges" all funnel into the same `split(segments:)`
/// call, so the three tests here also pin that a division expressed three different ways lands the same
/// bytes on disk — the "modes stay in sync" promise, checked at the level that actually ships (files),
/// not just the count label.
@Suite struct SplitVisualGridPipelineTests {

    /// The 1-based marker tokens on each output page, part by part — the shape the assertions compare.
    private func partTexts(_ outputs: [URL]) throws -> [[String]] {
        try outputs.map { try PDFFixtures.pageTexts(at: $0) }
    }

    @Test func cutsProduceExactlyThoseFilesAndPages() throws {
        // An 8-page document, cut after pages 3 and 6 in the grid → three files: P1-3, P4-6, P7-8.
        let dir = FixtureDir()
        let src = dir.url("doc.pdf")
        try PDFFixtures.writePDF(pageCount: 8, to: src)

        let segments = SplitCuts.segments(pageCount: 8, cuts: [3, 6])
        #expect(segments == [[0, 1, 2], [3, 4, 5], [6, 7]])

        let outputs = try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "doc", segments: segments)

        #expect(outputs.map(\.lastPathComponent) == ["doc-01.pdf", "doc-02.pdf", "doc-03.pdf"])
        #expect(try partTexts(outputs) == [
            [PDFFixtures.marker(1), PDFFixtures.marker(2), PDFFixtures.marker(3)],
            [PDFFixtures.marker(4), PDFFixtures.marker(5), PDFFixtures.marker(6)],
            [PDFFixtures.marker(7), PDFFixtures.marker(8)],
        ])
        // The per-file page counts the "3 + 3 + 2 pages" summary reports.
        #expect(segments.map(\.count) == [3, 3, 2])
    }

    @Test func everyNAndVisualCutsWriteIdenticalFiles() throws {
        // "Every 3 pages" and the visual cuts {3,6} must be the same split, byte-for-byte on disk.
        let visualDir = FixtureDir()
        let everyNDir = FixtureDir()
        try PDFFixtures.writePDF(pageCount: 8, to: visualDir.url("doc.pdf"))
        try PDFFixtures.writePDF(pageCount: 8, to: everyNDir.url("doc.pdf"))

        let visualSegments = SplitCuts.segments(pageCount: 8, cuts: SplitCuts.everyNCuts(pageCount: 8, chunkSize: 3))
        let everyNSegments = PageRangeParser.everyNPagesSegments(pageCount: 8, chunkSize: 3)
        #expect(visualSegments == everyNSegments)

        let visualOut = try PDFToolkit.split(inputURL: visualDir.url("doc.pdf"), into: visualDir.url, baseName: "doc", segments: visualSegments)
        let everyNOut = try PDFToolkit.split(inputURL: everyNDir.url("doc.pdf"), into: everyNDir.url, baseName: "doc", segments: everyNSegments)

        #expect(try partTexts(visualOut) == partTexts(everyNOut))
        #expect(visualOut.count == 3)
    }

    @Test func customRangesAndVisualCutsWriteIdenticalFiles() throws {
        // The typed custom ranges "1-3, 4-6, 7-8" describe the same partition as the visual cuts {3,6}.
        let customDir = FixtureDir()
        let visualDir = FixtureDir()
        try PDFFixtures.writePDF(pageCount: 8, to: customDir.url("doc.pdf"))
        try PDFFixtures.writePDF(pageCount: 8, to: visualDir.url("doc.pdf"))

        let customSegments = try PageRangeParser.parseSegments("1-3, 4-6, 7-8", pageCount: 8)
        let visualSegments = SplitCuts.segments(pageCount: 8, cuts: [3, 6])
        #expect(customSegments == visualSegments)

        let customOut = try PDFToolkit.split(inputURL: customDir.url("doc.pdf"), into: customDir.url, baseName: "doc", segments: customSegments)
        let visualOut = try PDFToolkit.split(inputURL: visualDir.url("doc.pdf"), into: visualDir.url, baseName: "doc", segments: visualSegments)

        #expect(try partTexts(customOut) == partTexts(visualOut))
    }

    @Test func noCutsWritesTheWholeDocumentAsOneFile() throws {
        // The visual grid's default (no cuts) is a single-file "split" — the whole document, in order.
        let dir = FixtureDir()
        let src = dir.url("doc.pdf")
        try PDFFixtures.writePDF(pageCount: 4, to: src)

        let segments = SplitCuts.segments(pageCount: 4, cuts: [])
        let outputs = try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "doc", segments: segments)

        #expect(outputs.map(\.lastPathComponent) == ["doc-01.pdf"])
        #expect(try partTexts(outputs) == [(1...4).map(PDFFixtures.marker)])
    }
}
