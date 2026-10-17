import Testing
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import PDFToolkitCore

/// Watermark stamps text onto every page while keeping the underlying page as vector content, so
/// its text stays selectable. Tests pin the required-text guard, page-count preservation, the
/// vector-preservation guarantee, both layout modes, and that an intrinsically rotated page is
/// emitted upright.
@Suite struct PDFToolkitWatermarkTests {

    private func options(_ text: String, tiled: Bool = false) -> WatermarkOptions {
        WatermarkOptions(
            text: text, fontSize: 48, opacity: 0.3, rotationDegrees: 45,
            red: 0.8, green: 0.1, blue: 0.1, tiled: tiled
        )
    }

    @Test func emptyOrWhitespaceTextThrowsWatermarkTextRequired() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        for text in ["", "   \n\t "] {
            #expect(#expect(throws: PDFOperationError.self) {
                try PDFToolkit.watermark(inputURL: src, outputURL: dir.url("out.pdf"), options: options(text))
            }?.kind == "watermarkTextRequired")
        }
    }

    @Test func preservesPageCount() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        #expect(try PDFFixtures.pageCount(at: out) == 3)
    }

    @Test func underlyingTextStaysSelectable() throws {
        // The page is copied as vector content (drawPDFPage), not rasterized — so the original
        // marker text is still extractable from the watermarked output.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("CONFIDENTIAL"))

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts[0].contains("MARKERPAGE1"))
    }

    @Test func bothTiledAndCenteredLayoutsProduceOutput() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        let centered = dir.url("centered.pdf"), tiled = dir.url("tiled.pdf")
        try PDFToolkit.watermark(inputURL: src, outputURL: centered, options: options("X", tiled: false))
        try PDFToolkit.watermark(inputURL: src, outputURL: tiled, options: options("X", tiled: true))

        #expect(try PDFFixtures.pageCount(at: centered) == 1)
        #expect(try PDFFixtures.pageCount(at: tiled) == 1)
    }

    @Test func handlesAnIntrinsicallyRotatedPageInput() throws {
        // A page with baked-in 90° rotation exercises the watermark renderer's displayed-size /
        // drawing-transform branch. It must still produce a valid, openable single page with the
        // original text preserved (vector copy) — without crashing on the rotated geometry.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ROTATED"], rotations: [0: 90], to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        let texts = try PDFFixtures.pageTexts(at: out)
        #expect(texts.count == 1)
        #expect(texts[0].contains("ROTATED"))
    }

    @Test func pdfLogoBitmapFollowsIntrinsicRotation() throws {
        // A portrait Letter logo page (612×792) with a baked-in 90° rotation DISPLAYS landscape. The
        // rasterized logo bitmap must follow the displayed orientation (wide), not the raw crop box
        // (tall) — otherwise a rotated PDF logo is drawn into a wrong-aspect bitmap and stamped
        // clipped/squashed. Pins the displayed-size + drawing-transform path in `firstPageImage`.
        let dir = FixtureDir()
        let logo = dir.url("logo.pdf")
        try PDFFixtures.writePDF(markers: ["LOGO"], rotations: [0: 90], to: logo)

        let image = try #require(PDFToolkit.watermarkImageSource(at: logo))
        #expect(image.cgImage.width > image.cgImage.height)   // displayed landscape, not raw portrait
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.watermark(inputURL: bad, outputURL: dir.url("out.pdf"), options: options("DRAFT"))
        }?.kind == "couldNotOpen")
    }

    @Test func visibleAnnotationsSurviveWatermarking() throws {
        // The watermark rebuild replays only the content stream via `drawPDFPage`, so annotation
        // appearances (form values, signatures, notes) silently vanished. They are now flattened
        // into the emitted page.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        let annotationRect = CGRect(x: 300, y: 300, width: 80, height: 60)
        try PDFFixtures.writePDF(markers: ["ONLY"], greenSquareOnFirstPage: annotationRect, to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(340, 330) < 0.8)   // green square present, not blank white
    }

    @Test func keepsTheSourcePageSizeInsteadOfDefaultingToUSLetter() throws {
        // beginPDFPage's media-box value must be CFData wrapping the CGRect; the bridged CGRect it
        // was fed before is silently ignored, so EVERY watermarked page came out 612x792 — an A4's
        // top 50pt of content simply fell off the page.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        let a4 = CGSize(width: 595, height: 842)
        // Marker text sits at y = height/2 = 421; also prove the page is truly A4-sized.
        try PDFFixtures.writePDF(markers: ["ONLY"], size: a4, to: src)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        #expect(try PDFFixtures.pageSize(at: out) == a4)
        let glyphs = PDFFixtures.darkestSample(
            try PDFFixtures.brightnessSampler(at: out),
            xRange: stride(from: 74, through: 160, by: 2), yValues: [425, 429, 433]
        )
        #expect(glyphs < 0.6)
    }

    @Test func aCroppedPageEmitsItsVisibleSize() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            markers: ["ONLY"],
            cropFirstPageTo: CGRect(x: 50, y: 50, width: 500, height: 600),
            greenSquareOnFirstPage: CGRect(x: 300, y: 300, width: 80, height: 60), to: src
        )

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options("DRAFT"))

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 500, height: 600))
        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(310, 290) < 0.8)   // annotation shifted by the crop origin exactly once
    }

    // MARK: - Page scope

    /// The darkest sample over a grid straddling the page center (306, 396 on US Letter), where a
    /// centered watermark lands but the left-edge fixture marker never reaches — so it tells a
    /// stamped page apart from an untouched (white-center) one.
    private func centerDarkest(_ sampler: (CGFloat, CGFloat) -> CGFloat) -> CGFloat {
        PDFFixtures.darkestSample(
            sampler,
            xRange: stride(from: 262, through: 350, by: 4),
            yValues: [372, 384, 396, 408, 420]
        )
    }

    /// An opaque, near-black, horizontal mark — its center pixels read clearly dark (< 0.5), so a
    /// scope test can assert stamped-vs-untouched without the faint default (30% red) confusing the
    /// threshold.
    private func opaqueOptions(_ text: String) -> WatermarkOptions {
        WatermarkOptions(
            text: text, fontSize: 60, opacity: 1.0, rotationDegrees: 0,
            red: 0.05, green: 0.05, blue: 0.05, tiled: false
        )
    }

    @Test func firstPageOnlyStampsOnlyTheFirstPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        var opts = opaqueOptions("DRAFT")
        opts.pageScope = .firstPageOnly
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: opts)

        #expect(try PDFFixtures.pageCount(at: out) == 2)                 // every page still emitted
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 0)) < 0.5)   // stamped
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 1)) > 0.95)  // untouched
    }

    @Test func customRangeStampsOnlyListedPages() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        var opts = opaqueOptions("DRAFT")
        opts.pageScope = .custom("2")   // one-based → page index 1 only
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: opts)

        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 0)) > 0.95)  // untouched
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 1)) < 0.5)   // stamped
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out, page: 2)) > 0.95)  // untouched
    }

    @Test func customRangeEmptyThrowsPageRangeRequired() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        var opts = options("DRAFT")
        opts.pageScope = .custom("   ")
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.watermark(inputURL: src, outputURL: dir.url("out.pdf"), options: opts)
        }?.kind == "pageRangeRequired")
    }

    @Test func customRangeBeyondTheDocumentThrowsPageOutOfBounds() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        var opts = options("DRAFT")
        opts.pageScope = .custom("5")
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.watermark(inputURL: src, outputURL: dir.url("out.pdf"), options: opts)
        }?.kind == "pageOutOfBounds")
    }

    // MARK: - Font

    @Test func watermarkFontResolvesAChosenFamilyAndFallsBackSafely() {
        #expect(PDFToolkit.watermarkFont(named: nil, size: 20).pointSize == 20)                 // default
        #expect(PDFToolkit.watermarkFont(named: "Helvetica", size: 20).familyName == "Helvetica")
        // An unknown family must not vanish the stamp — it falls back to a valid font.
        #expect(PDFToolkit.watermarkFont(named: "NoSuchFontFamily__42", size: 20).pointSize == 20)
    }

    @Test func aChosenFontStillProducesAValidWatermarkedPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)
        var opts = opaqueOptions("DRAFT")
        opts.fontName = "Times New Roman"
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: opts)
        #expect(try PDFFixtures.pageTexts(at: out)[0].contains("MARKERPAGE1"))   // underlying text intact
        #expect(centerDarkest(try PDFFixtures.brightnessSampler(at: out)) < 0.5) // stamp rendered
    }

    // MARK: - Image watermark

    /// Builds `WatermarkOptions` for the image branch (no text) with the given placement.
    private func imageOptions(
        _ image: WatermarkImage, opacity: CGFloat, scale: CGFloat, rotation: CGFloat = 0, tiled: Bool = false
    ) -> WatermarkOptions {
        WatermarkOptions(
            text: "", fontSize: 48, opacity: opacity, rotationDegrees: rotation,
            red: 0, green: 0, blue: 0, tiled: tiled,
            content: .image, image: image, imageScale: scale
        )
    }

    /// Writes a square PNG whose left half is opaque red and right half fully transparent — so a
    /// stamped copy can prove both that the logo lands AND that its transparency composites (the
    /// transparent half must let the page show through, not paint an opaque box).
    private func writeHalfTransparentPNG(to url: URL, side: Int = 100) throws {
        let ctx = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))   // left half opaque, right stays clear
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func missingImageThrowsWatermarkImageRequired() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        var opts = options("ignored")
        opts.content = .image
        opts.image = nil
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.watermark(inputURL: src, outputURL: dir.url("out.pdf"), options: opts)
        }?.kind == "watermarkImageRequired")
    }

    @Test func imageWatermarkStampsAndKeepsPNGTransparency() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf"), logo = dir.url("logo.png")
        try PDFFixtures.writePDF(pageCount: 1, to: src)   // white US-Letter page
        try writeHalfTransparentPNG(to: logo)

        let decoded = try #require(PDFToolkit.watermarkImageSource(at: logo))
        // The decode preserved an alpha channel (the whole point of the transparency support).
        let alpha = decoded.cgImage.alphaInfo
        #expect(alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast)

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: imageOptions(decoded, opacity: 1, scale: 0.5))

        // Centered 100×100 logo scaled ×3.06 → ~306pt square about (306, 396): red half ~x∈[153,306],
        // transparent half ~x∈[306,459].
        let b = try PDFFixtures.brightnessSampler(at: out)
        #expect(b(280, 396) < 0.8)   // opaque red half stamped
        #expect(b(400, 396) > 0.9)   // transparent half let the white page through
    }

    @Test func imageWatermarkRespectsOpacity() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), logo = dir.url("logo.png")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        try writeHalfTransparentPNG(to: logo)
        let decoded = try #require(PDFToolkit.watermarkImageSource(at: logo))

        let full = dir.url("full.pdf"), faint = dir.url("faint.pdf")
        try PDFToolkit.watermark(inputURL: src, outputURL: full, options: imageOptions(decoded, opacity: 1.0, scale: 0.5))
        try PDFToolkit.watermark(inputURL: src, outputURL: faint, options: imageOptions(decoded, opacity: 0.3, scale: 0.5))

        let solid = try PDFFixtures.brightnessSampler(at: full)(280, 396)
        let lighter = try PDFFixtures.brightnessSampler(at: faint)(280, 396)
        #expect(lighter > solid)   // lower opacity over white reads lighter
    }

    @Test func imageWatermarkOnlyMarksPagesInScope() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf"), logo = dir.url("logo.png")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        try writeHalfTransparentPNG(to: logo)
        let decoded = try #require(PDFToolkit.watermarkImageSource(at: logo))

        var opts = imageOptions(decoded, opacity: 1, scale: 0.5)
        opts.pageScope = .firstPageOnly
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: opts)

        #expect(try PDFFixtures.brightnessSampler(at: out, page: 0)(280, 396) < 0.8)   // stamped
        #expect(try PDFFixtures.brightnessSampler(at: out, page: 1)(280, 396) > 0.95)  // untouched
    }

    @Test func imageWatermarkOnACroppedPageCentersOnTheVisibleBox() throws {
        // The image branch through the displayed-size / crop-box path (its text-watermark siblings
        // above are covered; this pins the logo branch too). The logo centers on the *cropped* page,
        // and the emitted page is the crop's visible size — not the full media box.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf"), logo = dir.url("logo.png")
        try PDFFixtures.writePDF(
            markers: ["ONLY"], cropFirstPageTo: CGRect(x: 50, y: 50, width: 500, height: 600), to: src
        )
        try writeHalfTransparentPNG(to: logo)
        let decoded = try #require(PDFToolkit.watermarkImageSource(at: logo))

        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: imageOptions(decoded, opacity: 1, scale: 0.5))

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 500, height: 600))
        // Cropped page center = (250, 300); the 100×100 logo aspect-fits to 250×250 there, so its
        // opaque red half sits left of center and its transparent half lets the page show through.
        let b = try PDFFixtures.brightnessSampler(at: out)
        #expect(b(190, 300) < 0.8)   // opaque red half stamped left of the visible-box center
        #expect(b(320, 300) > 0.9)   // transparent half → white page through, on the cropped page
    }

    // MARK: - EXIF orientation baking

    /// Renders a decoded logo into a straight-RGBA buffer (row 0 = top) and classifies the dominant
    /// primary at a fractional point measured from the TOP-LEFT — so a test can read off exactly
    /// where each corner of the sensor image landed after the EXIF orientation was applied.
    private struct Quadrants {
        let width: Int, height: Int
        private let px: [UInt8]
        private let bytesPerRow: Int

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            let ctx = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytesPerRow = ctx.bytesPerRow
            let data = try #require(ctx.data)
            let ptr = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            px = Array(UnsafeBufferPointer(start: ptr, count: bytesPerRow * height))
        }

        /// The fixture's four quadrants use well-separated primaries, so a sample at a quadrant
        /// center resolves to exactly one label — a robust identity for "which corner is here?"
        /// that survives the gamma/color-management differences between two decode pipelines.
        func label(atX fx: CGFloat, y fy: CGFloat) -> String {
            let col = min(width - 1, max(0, Int(fx * CGFloat(width))))
            let row = min(height - 1, max(0, Int(fy * CGFloat(height))))
            let o = row * bytesPerRow + col * 4
            let r = CGFloat(px[o]) / 255, g = CGFloat(px[o + 1]) / 255, b = CGFloat(px[o + 2]) / 255
            if r > 0.5 && g > 0.5 { return "yellow" }
            if r > 0.5 { return "red" }
            if g > 0.5 { return "green" }
            if b > 0.5 { return "blue" }
            return "other"
        }
    }

    /// The four quadrant-center sample points (fx, fy from top-left), in TL, TR, BL, BR order.
    private static let quadrantSamples: [(CGFloat, CGFloat)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]

    /// Writes a non-square 4-quadrant PNG — sensor top-left red, top-right green, bottom-left blue,
    /// bottom-right yellow — tagged with the given EXIF orientation. Four distinct primaries and a
    /// non-square shape make every one of the eight orientations land the corners distinguishably,
    /// so a decoder that gets the transform wrong is caught. The pixels are the raw sensor content;
    /// only the metadata carries the orientation, exactly like a real camera file.
    private func writeQuadrantPNG(to url: URL, orientation: UInt32, w: Int = 80, h: Int = 120) throws {
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // y-up context: the top half is high y, so fill display-top quadrants at y = h/2…h.
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))     // TL red
        ctx.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)) // TR green
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))         // BL blue
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))     // BR yellow
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// Apple's own orientation-baking, used as the independent oracle: the full-size thumbnail with
    /// `kCGImageSourceCreateThumbnailWithTransform` applies the file's EXIF orientation to the pixels.
    private func appleUprighted(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,   // ≥ the fixture's longest side → no downscale
        ]
        return try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
    }

    @Test func orientationSixDecodesUprightNotUpsideDown() throws {
        // The advertised feature — "EXIF orientation baked in" — was backwards for the common
        // portrait-phone capture (orientation 6 = rotate 90° CW): the sensor was uprighted 90° CCW,
        // stamping such a logo upside-down. Rotating the sensor 90° CW moves its corners
        // TL→TR, TR→BR, BR→BL, BL→TL, so the uprighted quadrants read blue/red at the top and
        // yellow/green at the bottom. These four labels fail loudly on the pre-fix transform.
        let dir = FixtureDir()
        let logo = dir.url("logo6.png")
        try writeQuadrantPNG(to: logo, orientation: 6)

        let decoded = try #require(PDFToolkit.watermarkImageSource(at: logo))
        let q = try Quadrants(decoded.cgImage)
        #expect(q.label(atX: 0.25, y: 0.25) == "blue")     // TL ← sensor bottom-left
        #expect(q.label(atX: 0.75, y: 0.25) == "red")      // TR ← sensor top-left
        #expect(q.label(atX: 0.25, y: 0.75) == "yellow")   // BL ← sensor bottom-right
        #expect(q.label(atX: 0.75, y: 0.75) == "green")    // BR ← sensor top-right
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt32])
    func decodeMatchesApplesOrientationBaking(orientation: UInt32) throws {
        // The general oracle: our decode (`CGImageSourceCreateImageAtIndex` + `redrawUpright`) must
        // agree with Apple's baking for every orientation, at all four quadrant centers. This is the
        // exact comparison that would have caught the shipped 5↔7 / 6↔8 swap.
        let dir = FixtureDir()
        let logo = dir.url("logo\(orientation).png")
        try writeQuadrantPNG(to: logo, orientation: orientation)

        // Guard the fixture's own validity: PNG must carry the tag, or both paths would just see an
        // untagged (orientation 1) image and agree vacuously.
        let source = try #require(CGImageSourceCreateWithURL(logo as CFURL, nil))
        let tag = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32
        try #require(tag == orientation)

        let mine = try Quadrants(try #require(PDFToolkit.watermarkImageSource(at: logo)).cgImage)
        let apple = try Quadrants(try appleUprighted(at: logo))
        #expect(mine.width == apple.width && mine.height == apple.height)
        for (fx, fy) in Self.quadrantSamples {
            #expect(mine.label(atX: fx, y: fy) == apple.label(atX: fx, y: fy),
                    "orientation \(orientation) disagrees with Apple at (\(fx), \(fy))")
        }
    }

    /// The vector rebuild draws the page content under the rotation transform, then restores the
    /// state before flattening `/Annots`. That looks like a bug — an annotation drawn without the
    /// page transform — but `PDFAnnotation.draw(with:in:)` performs the display mapping itself, so
    /// applying the transform first is what rotates it TWICE. The raster path pins this already
    /// (`annotationsLandUprightOnARotatedPage`); this pins the vector path Watermark/OCR/Fill & Sign
    /// share, which a review flagged as corrupting rotated scans.
    ///
    /// Fixture: /Rotate 90 letter page, green square at page space (300,300)+(80x60) — displayed
    /// home is x 300–359, y 232–311 on the 792x612 page. The double-rotation bug would park it near
    /// x 232–311, y 252–311.
    @Test func watermarkKeepsExistingAnnotationsUprightOnARotatedPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            markers: ["ONLY"], rotations: [0: 90],
            greenSquareOnFirstPage: CGRect(x: 300, y: 300, width: 80, height: 60), to: src
        )
        // A near-invisible mark: this test is about where the EXISTING annotation lands, so the
        // watermark itself must not tint the samples.
        var options = WatermarkOptions(text: "W", fontSize: 10, opacity: 0.05,
                                       rotationDegrees: 0, red: 1, green: 0, blue: 0, tiled: false)
        options.pageScope = .all
        try PDFToolkit.watermarkData(inputURL: src, options: options).write(to: out)

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        #expect(brightness(335, 270) < 0.8)   // the annotation's displayed home
        #expect(brightness(250, 290) > 0.9)   // the double-rotated position stays blank
    }
}
