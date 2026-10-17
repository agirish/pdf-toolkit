import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import PDFToolkitCore

/// Redaction rasterizes each marked page and paints solid black over the marked regions, so their
/// content can't be recovered; unmarked pages are copied as-is (optionally stripped of annotations).
/// Tests pin that marked text truly disappears, unmarked text survives, the page count holds, and
/// the guard/annotation paths behave.
@Suite struct PDFToolkitRedactTests {

    /// A lower raster ceiling than the 4000px default keeps the bitmap work fast in tests.
    private let fastOptions = PDFRedactionExportOptions(
        stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 800
    )

    /// The full media box of a source page, so a mark is guaranteed to cover its text.
    private func fullPageRect(_ url: URL, page: Int) throws -> CGRect {
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: page)).bounds(for: .mediaBox)
    }

    @Test func noMarksThrowsNoRedactions() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.redact(inputURL: src, outputURL: dir.url("out.pdf"), marks: [], options: fastOptions)
        }?.kind == "noRedactions")
    }

    @Test func markOnAMissingPageThrowsPageOutOfBounds() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let mark = RedactionMark(pageIndex: 5, rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.redact(inputURL: src, outputURL: dir.url("out.pdf"), marks: [mark], options: fastOptions)
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }

    @Test func markedPageLosesItsTextWhileUnmarkedPagesKeepTheirs() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["SECRET1", "PUBLIC2", "PUBLIC3"], to: src)

        // Cover the whole first page.
        let mark = RedactionMark(pageIndex: 0, rect: try fullPageRect(src, page: 0))
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: [mark], options: fastOptions)

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 3)
        #expect(!texts[0].contains("SECRET1"))   // rasterized away
        #expect(texts[1].contains("PUBLIC2"))     // untouched
        #expect(texts[2].contains("PUBLIC3"))
    }

    @Test func stripAnnotationsRemovesThemFromUnredactedPages() throws {
        let dir = FixtureDir()
        let base = dir.url("base.pdf"), src = dir.url("annotated.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: base)
        // Add a note to the *unredacted* second page, writing the annotated copy to a distinct path
        // (writing a PDFDocument back to the file it was opened from is unreliable).
        let doc = try #require(PDFDocument(url: base))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .freeText, withProperties: nil
        )
        annotation.contents = "hidden note"
        try #require(doc.page(at: 1)).addAnnotation(annotation)
        #expect(doc.write(to: src))

        let mark = RedactionMark(pageIndex: 0, rect: try fullPageRect(src, page: 0))

        // Kept when the option is off.
        let kept = dir.url("kept.pdf")
        try PDFToolkit.redact(inputURL: src, outputURL: kept, marks: [mark],
                              options: PDFRedactionExportOptions(stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 800))
        #expect(try #require(PDFDocument(url: kept)).page(at: 1)?.annotations.isEmpty == false)

        // Stripped when the option is on.
        let stripped = dir.url("stripped.pdf")
        try PDFToolkit.redact(inputURL: src, outputURL: stripped, marks: [mark],
                              options: PDFRedactionExportOptions(stripAnnotationsFromUnredactedPages: true, maxPixelDimension: 800))
        #expect(try #require(PDFDocument(url: stripped)).page(at: 1)?.annotations.isEmpty == true)
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.redact(inputURL: bad, outputURL: dir.url("out.pdf"), marks: [mark], options: fastOptions)
        }?.kind == "couldNotOpen")
    }

    @Test func partialMarkBlacksOutOnlyTheCoveredRegionAndSparesTheRest() throws {
        // The strongest anti-corruption / anti-data-loss check for the most destructive tool: a mark
        // over only the top half must black out that half (covered content unrecoverable) while
        // leaving the bottom half — including its text — fully rendered (no over-deletion).
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writeTwoZonePage(top: "TOPSECRET", bottom: "BOTTOMKEEP", to: src)

        // US Letter is 612×792; the top half is y ∈ [396, 792], which contains only the top token.
        let topHalf = CGRect(x: 0, y: 396, width: 612, height: 396)
        try PDFToolkit.redact(
            inputURL: src, outputURL: out,
            marks: [RedactionMark(pageIndex: 0, rect: topHalf)], options: fastOptions
        )

        #expect(try PDFFixtures.pageCount(at: out) == 1)
        let brightness = try PDFFixtures.brightnessSampler(at: out)

        // Well inside the mask → solid black (the top token is under here and is gone).
        #expect(brightness(300, 600) < 0.2)
        #expect(brightness(90, 690) < 0.2)
        // Below the mask, blank background → still white: redaction did not spill past its rectangle.
        #expect(brightness(400, 220) > 0.7)
        // The bottom token survives — scanning a small band over its glyphs finds dark strokes, so it
        // was neither blacked out (over-deletion) nor blanked white (content loss).
        var bottomMin: CGFloat = 1
        for x in stride(from: 74, through: 262, by: 2) {
            for y in [84, 88, 92] {
                bottomMin = min(bottomMin, brightness(CGFloat(x), CGFloat(y)))
            }
        }
        #expect(bottomMin < 0.5)
    }

    @Test func supersampledRedactionKeepsPageContentAtFullSize() throws {
        // Regression: `getDrawingTransform` refuses to scale a page up, so mapping it straight into
        // the supersampled pixel rect drew it 1:1 and centered — every real redaction (the app's
        // raster ceiling is always >= 2400px) emitted its page content at a fraction of its size in
        // a field of white.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 400, y: 100, width: 120, height: 60))
        try PDFToolkit.redact(
            inputURL: src, outputURL: out, marks: [mark],
            options: PDFRedactionExportOptions(stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 2400)
        )

        #expect(try PDFFixtures.pageSize(at: out) == PDFFixtures.letter)
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        // The marker text still renders where the source drew it (baseline starts at x 72, y 396)...
        let glyphs = PDFFixtures.darkestSample(
            brightness, xRange: stride(from: 74, through: 200, by: 2), yValues: [400, 404, 408]
        )
        #expect(glyphs < 0.5)
        // ...and the black fill sits exactly where the mark was placed.
        #expect(brightness(460, 130) < 0.2)
    }

    @Test func redactingARotatedPageEmitsItsDisplayedSizeUpright() throws {
        // A /Rotate 90 US-Letter page displays landscape (792x612). The old raster sized its bitmap
        // and output page from the unrotated media box, letterboxing the content at ~77% inside a
        // portrait page.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1)], rotations: [0: 90], to: src)

        // Portrait-space rect (500, 100)+(60x40) lands at display x 100-140, y 52-112 — far from the text.
        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 500, y: 100, width: 60, height: 40))
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: [mark], options: fastOptions)

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 792, height: 612))
        #expect(try PDFFixtures.pageRotations(at: out) == [0])
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        // The portrait baseline (x 72..., y 396) maps to a vertical run near display x ~400,
        // descending from y ~540; glyph strokes must be there at full size.
        let glyphs = PDFFixtures.darkestSample(
            brightness, xRange: stride(from: 398, through: 406, by: 4),
            yValues: Array(stride(from: CGFloat(400), through: 535, by: 4))
        )
        #expect(glyphs < 0.5)
        #expect(brightness(120, 80) < 0.2)
    }

    @Test func visibleAnnotationsAreFlattenedIntoRedactedPagesUnlessCovered() throws {
        // Annotation appearances used to vanish from rasterized pages (`drawPDFPage` skips /Annots).
        // They must be baked in as pixels — and a mark placed over one must bury it in black.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        let annotationRect = CGRect(x: 300, y: 300, width: 80, height: 60)
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1)], greenSquareOnFirstPage: annotationRect, to: src)

        // Marked elsewhere: the green square survives as pixels (no longer a live annotation).
        let kept = dir.url("kept.pdf")
        try PDFToolkit.redact(
            inputURL: src, outputURL: kept,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 30, y: 30, width: 50, height: 40))],
            options: fastOptions
        )
        let keptBrightness = try PDFFixtures.brightnessSampler(at: kept)
        #expect(keptBrightness(340, 330) < 0.8)   // green, not blank white
        #expect(try #require(PDFDocument(url: kept)).page(at: 0)?.annotations.isEmpty == true)

        // Marked over the annotation: buried under solid black.
        let buried = dir.url("buried.pdf")
        try PDFToolkit.redact(
            inputURL: src, outputURL: buried,
            marks: [RedactionMark(pageIndex: 0, rect: annotationRect.insetBy(dx: -10, dy: -10))],
            options: fastOptions
        )
        let buriedBrightness = try PDFFixtures.brightnessSampler(at: buried)
        #expect(buriedBrightness(340, 330) < 0.2)
    }

    @Test func redactingACroppedPageTracksContentAndEmitsTheVisibleSize() throws {
        // Crop box (50,50)+(500x600): the emitted page is the visible size and the black fill lands
        // on the marked content after the crop-origin shift — mapped once, not twice.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            markers: [PDFFixtures.marker(1)],
            cropFirstPageTo: CGRect(x: 50, y: 50, width: 500, height: 600), to: src
        )

        // Cover the marker text (drawn at page-space x 72…, baseline y 396).
        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 60, y: 380, width: 220, height: 44))
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: [mark], options: fastOptions)

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 500, height: 600))
        #expect(!(try PDFFixtures.pageTexts(at: out)[0].contains(PDFFixtures.marker(1))))
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(100, 350) < 0.2)   // fill at display (10,330)+(220x44)
    }

    @Test func aMarkEntirelyOutsideTheCropStillRasterizesInsteadOfFailing() throws {
        // A drag in a cropped-out margin produces a mark whose fills clip to nothing. That used to
        // abort the WHOLE export with a generic redactionFailed; now the page still rasterizes
        // (destroying the out-of-crop content the mark covered — the safe direction) and the
        // export succeeds.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            markers: [PDFFixtures.marker(1)],
            cropFirstPageTo: CGRect(x: 50, y: 50, width: 500, height: 600), to: src
        )

        let outside = RedactionMark(pageIndex: 0, rect: CGRect(x: 0, y: 700, width: 40, height: 40))
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: [outside], options: fastOptions)

        #expect(try PDFFixtures.pageCount(at: out) == 1)
        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 500, height: 600))
        // Rasterized: the marker text is no longer extractable, proving the page did not fall back
        // to a vector copy that would keep recoverable content.
        #expect(!(try PDFFixtures.pageTexts(at: out)[0].contains(PDFFixtures.marker(1))))
    }

    // MARK: Detected-but-unmarkable matches (the export gate's engine half)

    /// The leak this exists to close: a page with no marks is copied through as vector, so text
    /// Find & redact DID detect but couldn't place a box on stays fully extractable.
    @Test func anUnmarkedPageKeepsItsTextByDefault() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2"], to: src)

        let data = try PDFToolkit.redactData(
            inputURL: src,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 50, y: 300, width: 300, height: 60))]
        )
        let texts = try PDFFixtures.pageTexts(data: data)
        #expect(!texts[0].contains("P1"))   // marked page rasterized
        #expect(texts[1].contains("P2"))    // unmarked page still vector, text intact
    }

    /// `forceRasterizePages` is what the user's "remove the text on page N" choice becomes: the page
    /// carries no marks and gets no black box, but it is re-emitted as an image so nothing on it can
    /// be extracted any more.
    @Test func forceRasterizeRemovesTextFromAnUnmarkedPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2"], to: src)

        var options = PDFRedactionExportOptions.default
        options.forceRasterizePages = [1]
        let data = try PDFToolkit.redactData(
            inputURL: src,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 50, y: 300, width: 300, height: 60))],
            options: options
        )
        let texts = try PDFFixtures.pageTexts(data: data)
        #expect(!texts[0].contains("P1"))
        #expect(!texts[1].contains("P2"), "page 2 was force-rasterized, so its text must be gone")
        #expect(try #require(PDFDocument(data: data)).pageCount == 2)
    }

    /// Only the named pages lose their text — the option must not escalate into "rasterize the
    /// whole document", which would cost quality and size on every untouched page.
    @Test func forceRasterizeLeavesOtherPagesAsVector() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)

        var options = PDFRedactionExportOptions.default
        options.forceRasterizePages = [1]
        let data = try PDFToolkit.redactData(
            inputURL: src,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 50, y: 300, width: 300, height: 60))],
            options: options
        )
        let texts = try PDFFixtures.pageTexts(data: data)
        #expect(!texts[1].contains("P2"))
        #expect(texts[2].contains("P3"), "page 3 was neither marked nor named, so it stays vector")
    }

    /// The case the option exists for: every match unlocatable, so nothing is drawn and the ONLY
    /// thing to do is destroy the text. This used to be impossible — the engine refused any export
    /// without marks, so the user was warned about a leak they could not act on.
    @Test func aForcedPageAloneIsAValidExport() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2"], to: src)

        var options = PDFRedactionExportOptions.default
        options.forceRasterizePages = [1]
        let texts = try PDFFixtures.pageTexts(
            data: try PDFToolkit.redactData(inputURL: src, marks: [], options: options))

        #expect(!texts[1].contains("P2"), "the named page's text must be gone")
        #expect(texts[0].contains("P1"), "and no other page may be touched")
    }

    /// Neither marks nor forced pages is still nothing to do.
    @Test func noMarksAndNoForcedPagesStillThrows() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.redactData(inputURL: src, marks: [])
        }?.kind == "noRedactions")
    }

    /// A bad index must fail loudly, like a mark's does. Silently ignoring it is the worst outcome
    /// available here: the caller is told the text was destroyed while the page shipped intact.
    @Test func aForcedPageOutOfBoundsThrows() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        var options = PDFRedactionExportOptions.default
        options.forceRasterizePages = [7]
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.redactData(
                inputURL: src,
                marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 10, y: 10, width: 40, height: 20))],
                options: options
            )
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 8) } else {
            Issue.record("expected pageOutOfBounds(8), got \(String(describing: error))")
        }
    }

    /// A forced page goes through the same raster path a marked page does, so it comes out upright
    /// at its displayed size with /Rotate baked in — pinned so this option can't start emitting a
    /// differently-shaped page than the rest of the tool.
    @Test func aForcedRotatedPageKeepsItsDisplayedGeometry() throws {
        let dir = FixtureDir()
        let src = dir.url("rot.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2"], rotations: [1: 90], to: src)

        var options = PDFRedactionExportOptions.default
        options.forceRasterizePages = [1]
        let data = try PDFToolkit.redactData(
            inputURL: src,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 50, y: 300, width: 200, height: 40))],
            options: options
        )
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 1))
        // 612x792 turned 90° displays as 792x612; the raster carries that, with rotation reset.
        #expect(page.bounds(for: .cropBox).size == CGSize(width: 792, height: 612))
        #expect(page.rotation == 0)
    }
}
