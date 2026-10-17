import Testing
import CoreGraphics
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Fill & Sign bakes typed text (as selectable vector text) and drawn signatures (as vector ink) onto
/// their pages while keeping the underlying page vector. These tests pin the no-items guard, page-count
/// and vector-text preservation, that placed text is extractable and lands where its rect says, that a
/// signature paints visible ink in its rectangle, and that items are routed to the right page.
@Suite struct PDFToolkitFillSignTests {

    private func textItem(_ string: String, page: Int, rect: CGRect, fontSize: CGFloat = 18) -> FillSignItem {
        FillSignItem(
            pageIndex: page,
            rect: rect,
            content: .text(FillSignText(string: string, fontSize: fontSize, red: 0, green: 0, blue: 0))
        )
    }

    @Test func noInkedItemsThrows() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        // Empty list, and a list whose only item is blank text — both are "nothing to bake".
        for items in [[], [textItem("   ", page: 0, rect: CGRect(x: 100, y: 100, width: 120, height: 30))]] {
            #expect(#expect(throws: PDFOperationError.self) {
                try PDFToolkit.fillAndSign(inputURL: src, outputURL: dir.url("out.pdf"), items: items)
            }?.kind == "noFillSignItems")
        }
    }

    @Test func preservesPageCountAndUnderlyingText() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1", "MARKERPAGE2"], to: src)

        try PDFToolkit.fillAndSign(
            inputURL: src,
            outputURL: out,
            items: [textItem("FILLED", page: 0, rect: CGRect(x: 120, y: 400, width: 200, height: 30))]
        )

        #expect(try PDFFixtures.pageCount(at: out) == 2)
        // The page was copied as vector content, so its original marker text survives.
        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains("MARKERPAGE1"))
        #expect(texts[1].contains("MARKERPAGE2"))
    }

    @Test func placedTextIsSelectableInTheExport() throws {
        // Typed runs must remain real, extractable vector text — not a rasterized stamp.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        try PDFToolkit.fillAndSign(
            inputURL: src,
            outputURL: out,
            items: [textItem("HELLOFILL", page: 0, rect: CGRect(x: 100, y: 300, width: 260, height: 40), fontSize: 28)]
        )

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains("HELLOFILL"))
    }

    @Test func placedTextLandsInsideItsRectangle() throws {
        // The text box top-left is (minX, maxY) in PDF space; the first line sits just below maxY. A
        // brightness probe across the box's upper band must find glyph strokes there.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)   // marker text is far away, near mid-page-left

        let rect = CGRect(x: 300, y: 650, width: 240, height: 60)
        try PDFToolkit.fillAndSign(
            inputURL: src,
            outputURL: out,
            items: [textItem("XYZ", page: 0, rect: rect, fontSize: 40)]
        )

        let sampler = try PDFFixtures.brightnessSampler(at: out)
        // Sample the top band of the box (just under maxY, where the first line draws).
        let darkest = PDFFixtures.darkestSample(
            sampler,
            xRange: stride(from: rect.minX + 4, through: rect.maxX - 4, by: 4),
            yValues: [rect.maxY - 12, rect.maxY - 24, rect.maxY - 36]
        )
        #expect(darkest < 0.6)   // glyph ink present in the box
    }

    @Test func drawnSignaturePaintsInkInItsRectangle() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        // A diagonal stroke across the normalized box (y-down), so it crosses the rect's interior.
        let signature = FillSignSignature(
            strokes: [[CGPoint(x: 0.05, y: 0.5), CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.95, y: 0.5)]],
            red: 0, green: 0, blue: 0,
            penWidthFraction: 0.06
        )
        let rect = CGRect(x: 200, y: 200, width: 240, height: 100)
        let item = FillSignItem(pageIndex: 0, rect: rect, content: .signature(signature))

        try PDFToolkit.fillAndSign(inputURL: src, outputURL: out, items: [item])

        #expect(try PDFFixtures.pageCount(at: out) == 1)
        let sampler = try PDFFixtures.brightnessSampler(at: out)
        // The stroke passes through the horizontal midline of the box near its left/right thirds.
        let darkest = PDFFixtures.darkestSample(
            sampler,
            xRange: stride(from: rect.minX + 10, through: rect.maxX - 10, by: 4),
            yValues: [rect.midY - 10, rect.midY, rect.midY + 10, rect.maxY - 12]
        )
        #expect(darkest < 0.6)   // signature ink present
    }

    @Test func itemsAreBakedOntoTheirOwnPage() throws {
        // An item on page 2 must not bleed onto page 1: page 1 stays blank in the target zone.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["A", "B"], to: src)

        let rect = CGRect(x: 300, y: 650, width: 200, height: 50)
        try PDFToolkit.fillAndSign(
            inputURL: src,
            outputURL: out,
            items: [textItem("PAGETWO", page: 1, rect: rect, fontSize: 36)]
        )

        let onPage2 = try PDFFixtures.pageTexts(at: out)[1]
        #expect(onPage2.contains("PAGETWO"))

        // Page 1 in that same rectangle is still white (no bleed-through).
        let page1 = try PDFFixtures.brightnessSampler(at: out, page: 0)
        let darkestOnPage1 = PDFFixtures.darkestSample(
            page1,
            xRange: stride(from: rect.minX + 4, through: rect.maxX - 4, by: 8),
            yValues: [rect.maxY - 12, rect.midY, rect.minY + 12]
        )
        #expect(darkestOnPage1 > 0.85)   // blank where page 2's text is
    }

    @Test func rejectsAnOutputThatMatchesTheInput() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.fillAndSign(
                inputURL: src,
                outputURL: src,
                items: [textItem("X", page: 0, rect: CGRect(x: 100, y: 100, width: 120, height: 30))]
            )
        }?.kind == "outputMatchesInput")
    }

    @Test func pageIndexOutOfBoundsThrows() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.fillAndSign(
                inputURL: src,
                outputURL: dir.url("out.pdf"),
                items: [textItem("X", page: 5, rect: CGRect(x: 100, y: 100, width: 120, height: 30))]
            )
        }?.kind == "pageOutOfBounds")
    }

    @Test func aCroppedPageEmitsItsVisibleSizeWithItemsAndAnnotationsPlacedOnce() throws {
        // Same geometry contract as watermark: the emitted page is the displayed crop size (the
        // media-box value must be CFData — a bridged CGRect was ignored, defaulting every page to
        // US Letter), placed items ride the page transform, and annotation appearances draw in
        // display space (drawing them under the page transform shifted them by the crop origin).
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            markers: ["ONLY"],
            cropFirstPageTo: CGRect(x: 50, y: 50, width: 500, height: 600),
            greenSquareOnFirstPage: CGRect(x: 300, y: 300, width: 80, height: 60), to: src
        )

        try PDFToolkit.fillAndSign(
            inputURL: src,
            outputURL: out,
            items: [textItem("XX", page: 0, rect: CGRect(x: 300, y: 450, width: 150, height: 40), fontSize: 30)]
        )

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 500, height: 600))
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        // Placed text at page-space (300,450) → display (250,400): glyph strokes in that band.
        let glyphs = PDFFixtures.darkestSample(
            brightness, xRange: stride(from: 252, through: 286, by: 2), yValues: [415, 420, 425]
        )
        #expect(glyphs < 0.6)
        #expect(brightness(310, 290) < 0.8)   // annotation at (250,250)+(80x60), origin subtracted once
        #expect(brightness(215, 215) > 0.9)   // double-subtraction home — blank now
    }

    @Test func typedTextBakesUprightOnARotatedPage() throws {
        // NSStringDrawing lays glyphs along the CTM's axes, so drawing under the rotated page
        // transform baked text sideways on /Rotate pages while the editor previewed it upright.
        // Fixture: /Rotate 90 letter page, item rect page-space (300,200)+(40x200), which displays
        // as a wide box at display x 200-400, y 272-312. A short "XX" at 24pt lands as one line at
        // the display box's top-left (x ~200-235); the sideways bug put its ink only at x 376-400.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONLY"], rotations: [0: 90], to: src)

        try PDFToolkit.fillAndSign(
            inputURL: src,
            outputURL: out,
            items: [textItem("XX", page: 0, rect: CGRect(x: 300, y: 200, width: 40, height: 200), fontSize: 24)]
        )

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 792, height: 612))
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        let upright = PDFFixtures.darkestSample(
            brightness, xRange: stride(from: 202, through: 240, by: 2), yValues: [295, 300, 305]
        )
        #expect(upright < 0.6)
        let sideways = PDFFixtures.darkestSample(
            brightness, xRange: stride(from: 370, through: 405, by: 2), yValues: [280, 295, 305]
        )
        #expect(sideways > 0.9)
    }
}
