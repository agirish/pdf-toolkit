import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Compress rebuilds every page as a bitmap wrapped in a new PDF — shrinking scans at the cost of
/// selectable text. Tests pin that the page count survives, that pages come out rasterized (text no
/// longer extractable, intrinsic rotation baked flat), and that extreme quality values are clamped
/// rather than crashing.
///
/// The raster-mechanics tests drive the core via `PDFFixtures.rasterize` rather than the public
/// `compress(inputURL:outputURL:quality:)`: that is a save path and is bounded by the input's size,
/// so on these deliberately lean text fixtures — which INFLATE when rasterized — it correctly passes
/// the original bytes through instead. That bound is pinned in `PDFToolkitReviewFollowUpTests`.
@Suite struct PDFToolkitCompressTests {

    @Test func preservesPageCount() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        try PDFToolkit.compress(inputURL: src, outputURL: out, quality: 0.5)

        #expect(try PDFFixtures.pageCount(at: out) == 3)
    }

    @Test func rasterizesPagesSoTextIsNoLongerSelectable() throws {
        // Each page becomes an image, so the marker text can't be extracted from the output.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)

        try PDFFixtures.rasterize(src, to: out, quality: 0.5)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(!texts[0].contains("MARKERPAGE1"))
    }

    @Test func bakesIntrinsicRotationFlatIntoTheBitmap() throws {
        // The renderer draws the page upright, then the new image page is stored at rotation 0 —
        // re-applying the source rotation would double it.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONLY"], rotations: [0: 90], to: src)

        try PDFFixtures.rasterize(src, to: out, quality: 0.5)

        #expect(try PDFFixtures.pageRotations(at: out) == [0])
    }

    @Test func clampsQualityBelowAndAboveTheValidRange() throws {
        // quality 0 and quality 5 are clamped into [0.05, 1]; both produce a valid output.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        let low = dir.url("low.pdf"), high = dir.url("high.pdf")
        try PDFToolkit.compress(inputURL: src, outputURL: low, quality: 0)
        try PDFToolkit.compress(inputURL: src, outputURL: high, quality: 5)

        #expect(try PDFFixtures.pageCount(at: low) == 2)
        #expect(try PDFFixtures.pageCount(at: high) == 2)
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.compress(inputURL: bad, outputURL: dir.url("out.pdf"), quality: 0.5)
        }?.kind == "couldNotOpen")
    }

    @Test func compressingARotatedPageKeepsItsDisplayedSize() throws {
        // A /Rotate 90 US-Letter page displays landscape (792x612). The old raster kept the
        // unrotated portrait box, letterboxing the upright content at ~77% between white bars.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONLY"], rotations: [0: 90], to: src)

        try PDFFixtures.rasterize(src, to: out, quality: 1.0)

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 792, height: 612))
        #expect(try PDFFixtures.pageRotations(at: out) == [0])
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        // "ONLY" runs from portrait (72, 396), which maps to a vertical run near display x ~400,
        // y ~485-540; strokes there prove the content is upright and unshrunken.
        let glyphs = PDFFixtures.darkestSample(
            brightness, xRange: stride(from: 398, through: 406, by: 4),
            yValues: Array(stride(from: CGFloat(490), through: 535, by: 3))
        )
        #expect(glyphs < 0.5)
    }

    @Test func visibleAnnotationsSurviveCompression() throws {
        // `drawPDFPage` replays only the content stream, so the rebuilt page silently lost every
        // annotation appearance — typed form values, signatures, notes. They must be baked in.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        let annotationRect = CGRect(x: 300, y: 300, width: 80, height: 60)
        try PDFFixtures.writePDF(markers: ["ONLY"], greenSquareOnFirstPage: annotationRect, to: src)

        try PDFFixtures.rasterize(src, to: out, quality: 1.0)

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(340, 330) < 0.8)   // green square present, not blank white
        #expect(try #require(PDFDocument(url: out)).page(at: 0)?.annotations.isEmpty == true)
    }

    @Test func annotationsLandUprightOnARotatedPage() throws {
        // PDFAnnotation.draw maps into displayed-page space itself; drawing it under the page
        // transform rotated it twice. Fixture: /Rotate 90 letter page, green square at page-space
        // (300,300)+(80x60) — displayed (rotated) home is x 300-359, y 232-311 on the 792x612 page;
        // the double-rotation bug parked it around x 232-311, y 252-311 instead.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            markers: ["ONLY"], rotations: [0: 90],
            greenSquareOnFirstPage: CGRect(x: 300, y: 300, width: 80, height: 60), to: src
        )

        try PDFFixtures.rasterize(src, to: out, quality: 1.0)

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(335, 270) < 0.8)   // inside the correct displayed rect (and outside the buggy one)
        #expect(brightness(250, 290) > 0.9)   // inside the buggy rect only — must be blank now
    }

    @Test func aCroppedPageKeepsItsVisibleSizeAndPlacement() throws {
        // Crop box (50,50)+(500x600) on a letter page: the output page must be the 500x600 the user
        // sees, with content AND annotations shifted by the crop origin exactly once. The old
        // annotation path subtracted the origin twice.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            markers: ["ONLY"],
            cropFirstPageTo: CGRect(x: 50, y: 50, width: 500, height: 600),
            greenSquareOnFirstPage: CGRect(x: 300, y: 300, width: 80, height: 60), to: src
        )

        try PDFFixtures.rasterize(src, to: out, quality: 1.0)

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 500, height: 600))
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(310, 290) < 0.8)   // green square at (250,250)+(80x60): origin subtracted once
        #expect(brightness(215, 215) > 0.9)   // where double-subtraction used to put it — blank now
    }

    // MARK: - Progress & cancellation

    @Test func progressReportsEveryPageOnceInOrderEndingAtTheTotal() throws {
        // Drives the sidebar's determinate bar: the engine must fire the callback once per page, with a
        // monotonic 1-based index and a constant total, so a long single-file run reads "page N of M".
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        final class Progress: @unchecked Sendable {
            var pages: [Int] = []
            var totals: Set<Int> = []
        }
        let seen = Progress()
        _ = try PDFToolkit.compressData(
            inputURL: src, quality: 0.5,
            onProgress: { page, total in
                seen.pages.append(page)
                seen.totals.insert(total)
            }
        )
        #expect(seen.pages == [1, 2, 3])   // once per page, monotonic, ending at the page count
        #expect(seen.totals == [3])        // total is always the page count
    }

    @Test func cancellationAbortsCompressBetweenPages() throws {
        // The Cancel button trips this probe; an always-true probe must stop the run at the FIRST page
        // and surface as `CancellationError` — the outcome the UI treats as a non-error (no alert/log).
        // A progress collector proves it stopped *between* pages: the engine reports a page, then polls
        // cancel, so with a 3-page fixture only page 1 is seen before the throw. Asserting the throw
        // alone would also pass for an engine that rendered all 3 pages and then threw.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        final class Progress: @unchecked Sendable { var pages: [Int] = [] }
        let seen = Progress()
        #expect(throws: CancellationError.self) {
            _ = try PDFToolkit.compressData(
                inputURL: src, quality: 0.5,
                onProgress: { page, _ in seen.pages.append(page) },
                isCancelled: { true }
            )
        }
        #expect(seen.pages == [1])   // aborted after page 1 was reported, before pages 2–3 — stopped early
    }

    @Test func cancellationAbortsTheTargetSizeSweep() throws {
        // The target sweep rebuilds the document at several qualities; an unreachably small target forces
        // it into the ladder (skipping the pass-through), where cancellation must abort mid-pass too.
        // The progress collector proves the abort lands inside the FIRST ladder pass, on page 1 — not
        // after rebuilding the whole document (or several ladder rungs) and only then throwing.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        final class Progress: @unchecked Sendable { var pages: [Int] = [] }
        let seen = Progress()
        #expect(throws: CancellationError.self) {
            _ = try PDFToolkit.compressToTargetData(
                inputURL: src, targetBytes: 1,
                onProgress: { page, _ in seen.pages.append(page) },
                isCancelled: { true }
            )
        }
        #expect(seen.pages == [1])   // one page reported in the first pass, then the throw — no full rebuild
    }
}
