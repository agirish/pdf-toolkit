import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// Geometry of the Crop operation: displayed-edge insets land on the correct stored edges under
/// every intrinsic rotation, existing (non-zero-origin) crop boxes compose, auto-detect wraps the
/// rendered content, and degenerate crops are refused.
@Suite struct PDFToolkitCropTests {

    private func cropBox(at url: URL, page index: Int = 0) throws -> CGRect {
        let doc = try #require(PDFDocument(url: url))
        return try #require(doc.page(at: index)).bounds(for: .cropBox)
    }

    // MARK: insetRect geometry (pure)

    @Test func insetsMapToStoredEdgesUnderEveryRotation() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)
        let insets = CropInsets(top: 1, left: 2, bottom: 3, right: 4)

        // rotation 0: what you see is what is stored.
        #expect(PDFToolkit.insetRect(rect, rotation: 0, by: insets)
                == CGRect(x: 12, y: 23, width: 294, height: 396))
        // rotation 90 (stored left edge shows on top): top→minX, right→maxY, bottom→maxX, left→minY.
        #expect(PDFToolkit.insetRect(rect, rotation: 90, by: insets)
                == CGRect(x: 11, y: 22, width: 296, height: 394))
        // rotation 180 (upside down): top→minY, right→minX, bottom→maxY, left→maxX.
        #expect(PDFToolkit.insetRect(rect, rotation: 180, by: insets)
                == CGRect(x: 14, y: 21, width: 294, height: 396))
        // rotation 270 (stored right edge shows on top): top→maxX, right→minY, bottom→minX, left→maxY.
        #expect(PDFToolkit.insetRect(rect, rotation: 270, by: insets)
                == CGRect(x: 13, y: 24, width: 296, height: 394))
        // Negative rotations normalize (-90 ≡ 270).
        #expect(PDFToolkit.insetRect(rect, rotation: -90, by: insets)
                == PDFToolkit.insetRect(rect, rotation: 270, by: insets))
    }

    // MARK: Interactive marquee preview (form/annotation strip)

    @Test func interactivePreviewStripsAnnotationsButKeepsGeometry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("annotated.pdf")

        let crop = CGRect(x: 30, y: 40, width: 500, height: 600)
        try PDFFixtures.writePDF(
            markers: ["content"],
            rotations: [0: 90],
            cropFirstPageTo: crop,
            greenSquareOnFirstPage: CGRect(x: 50, y: 60, width: 100, height: 100),
            to: url
        )
        let source = try #require(PDFDocument(url: url))
        #expect(source.page(at: 0)?.annotations.isEmpty == false)

        let preview = PDFToolkit.interactivePreviewDocument(from: source)
        // Same pages, no annotations — nothing for a live PDFView to form-fill or analyze.
        #expect(preview.pageCount == source.pageCount)
        let previewPage = try #require(preview.page(at: 0))
        #expect(previewPage.annotations.isEmpty)
        // Geometry the marquee maps through is untouched: crop box and intrinsic rotation survive.
        #expect(previewPage.bounds(for: .cropBox) == crop)
        #expect(previewPage.rotation == 90)
    }

    @Test func loupeSourceRenderCarriesActualPageContent() throws {
        // The loupe magnifies a PDFKit render of the page. It used to snapshot the PDFView with
        // `cacheDisplay(in:to:)`, which cannot capture PDFView's CALayer-drawn page — the loupe showed
        // an empty circle. Pin that the render path actually produces inked pixels.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("content.pdf")
        try PDFFixtures.writePDF(markers: ["LOUPE"], to: url)
        let page = try #require(PDFDocument(url: url)?.page(at: 0))

        let bounds = page.bounds(for: .cropBox)
        let image = page.thumbnail(
            of: NSSize(width: bounds.width * 2.5, height: bounds.height * 2.5),
            for: .cropBox
        )
        #expect(image.size.width > 1 && image.size.height > 1)

        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var inked = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent < 2.7 { inked += 1 }
            }
        }
        #expect(inked > 0, "the loupe's page render is blank — it would magnify nothing")
    }

    @Test func topAndRightEdgeHandlesAreGrabbableOnlyAfterExpandingTheGrabRegion() {
        // The marquee's top and right handles sit exactly on the page's max edges. `CGRect.contains`
        // excludes the max-X/max-Y edges, so the old "press must be inside the page" gate rejected a
        // grab right on those handles — the bug behind "crop doesn't work from the top-left/right".
        let page = CGRect(x: 0, y: 0, width: 100, height: 200)
        let topRight = CGPoint(x: page.maxX, y: page.maxY)
        #expect(page.contains(topRight) == false)

        // Growing the page by the handle grab radius (18 pt, CropMarqueeOverlayView.handleHitRadius)
        // makes every edge and corner handle reachable, including from a hair off the page.
        let grabRadius: CGFloat = 18
        let grabbable = page.insetBy(dx: -grabRadius, dy: -grabRadius)
        #expect(grabbable.contains(topRight))
        #expect(grabbable.contains(CGPoint(x: page.minX, y: page.maxY)))   // top-left
        #expect(grabbable.contains(CGPoint(x: page.maxX, y: page.midY)))   // right-mid
    }

    @Test func interactivePreviewKeepsPageCountSoIndicesStayAlignedWithTheOriginal() throws {
        // The marquee's page index is applied to the ORIGINAL file at crop time, so the preview copy
        // must have exactly the same page count — a short copy would crop the wrong page.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("multi.pdf")
        _ = try PDFFixtures.writePDF(pageCount: 5, to: url)
        let source = try #require(PDFDocument(url: url))

        let preview = PDFToolkit.interactivePreviewDocument(from: source)
        #expect(preview.pageCount == source.pageCount)
    }

    @Test func insetsFromSelectionInvertInsetRectUnderEveryRotation() {
        // A crop box with a NON-zero origin — the case origin-zero fixtures have hidden before.
        let cropBox = CGRect(x: 30, y: 40, width: 500, height: 600)
        let insets = CropInsets(top: 12, left: 34, bottom: 56, right: 7)

        for rotation in [0, 90, 180, 270, -90, 450] {
            // Drawing the box the numbers describe, then reading the numbers back off that box,
            // must return exactly the numbers — the two-way marquee/field sync depends on it.
            let box = PDFToolkit.insetRect(cropBox, rotation: rotation, by: insets)
            let recovered = PDFToolkit.insets(from: box, rotation: rotation, in: cropBox)
            #expect(recovered == insets)
        }
    }

    @Test func insetsFromSelectionMeasuresVisualEdgesAtRotation90() {
        // Stored space: a selection inset 10 off the left edge and 20 off the bottom of the box.
        let cropBox = CGRect(x: 0, y: 0, width: 400, height: 500)
        let selection = CGRect(x: 10, y: 20, width: 400 - 10 - 30, height: 500 - 20 - 40)
        // At 90° the stored left edge is the visual TOP and the stored bottom edge is the visual LEFT.
        let insets = PDFToolkit.insets(from: selection, rotation: 90, in: cropBox)
        #expect(insets == CropInsets(top: 10, left: 20, bottom: 30, right: 40))
    }

    @Test func insetsFromSelectionFlushWithAnEdgeReadsAsZeroTrim() {
        let cropBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        // A selection nudged a hair PAST the top/right edges must not report a negative trim.
        let selection = CGRect(x: 50, y: 0, width: 160, height: 210)
        let insets = PDFToolkit.insets(from: selection, rotation: 0, in: cropBox)
        #expect(insets.top == 0)
        #expect(insets.right == 0)
        #expect(insets.left == 50)
    }

    // MARK: crop()

    @Test func cropInsetsEveryPagesBox() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.crop(
            inputURL: src,
            outputURL: out,
            insets: CropInsets(top: 10, left: 20, bottom: 30, right: 40)
        )

        // Letter is 612×792 with origin 0,0.
        let expected = CGRect(x: 20, y: 30, width: 612 - 20 - 40, height: 792 - 10 - 30)
        #expect(try cropBox(at: out, page: 0) == expected)
        #expect(try cropBox(at: out, page: 1) == expected)
        #expect(try PDFFixtures.pageTexts(at: out) == PDFFixtures.pageTexts(at: src))
    }

    @Test func cropAppliesToOnlyTheGivenPagesAndLeavesTheRestUntouched() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let out = dir.url("out.pdf")

        // The marquee's "this page only" path: crop page 2 (index 1), copy pages 1 and 3 as-is.
        try PDFToolkit.crop(
            inputURL: src,
            outputURL: out,
            insets: CropInsets(top: 10, left: 20, bottom: 30, right: 40),
            pageIndices: [1]
        )

        let full = CGRect(x: 0, y: 0, width: 612, height: 792)
        #expect(try cropBox(at: out, page: 0) == full)
        #expect(try cropBox(at: out, page: 1) == CGRect(x: 20, y: 30, width: 612 - 20 - 40, height: 792 - 10 - 30))
        #expect(try cropBox(at: out, page: 2) == full)
        #expect(try PDFFixtures.pageTexts(at: out) == PDFFixtures.pageTexts(at: src))
    }

    @Test func cropComposesWithAnExistingNonZeroOriginCropBox() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // First page already cropped to a box that does not start at the origin.
        try PDFFixtures.writePDF(
            markers: [PDFFixtures.marker(1)],
            cropFirstPageTo: CGRect(x: 50, y: 60, width: 400, height: 500),
            to: src
        )
        let out = dir.url("out.pdf")

        try PDFToolkit.crop(
            inputURL: src,
            outputURL: out,
            insets: CropInsets(top: 5, left: 6, bottom: 7, right: 8)
        )

        // Insets apply to the *current* crop box, not the media box.
        #expect(try cropBox(at: out) == CGRect(x: 56, y: 67, width: 400 - 6 - 8, height: 500 - 5 - 7))
    }

    @Test func cropHonorsIntrinsicRotationOnStoredEdges() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // One page rotated 90°: the viewer's "top" is the stored minX edge.
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1)], rotations: [0: 90], to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.crop(inputURL: src, outputURL: out, insets: CropInsets(top: 50))

        #expect(try cropBox(at: out) == CGRect(x: 50, y: 0, width: 612 - 50, height: 792))
        // And the rotation itself survives the copy.
        let doc = try #require(PDFDocument(url: out))
        #expect(try #require(doc.page(at: 0)).rotation == 90)
    }

    @Test func degenerateCropThrowsWithThePageNumber() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.crop(
                inputURL: src,
                outputURL: dir.url("out.pdf"),
                insets: CropInsets(top: 400, bottom: 400)
            )
        }
        #expect(error?.kind == "cropTooSmall")
        if case .cropTooSmall(let page) = error { #expect(page == 1) }
    }

    // MARK: Drag-to-crop pipeline (selection → insets → output)

    @Test func marqueeSelectionBecomesTheOutputCropBoxUnderRotationAndOffsetOrigin() throws {
        // Mirrors the drag flow end to end: the overlay holds a selection rect in stored page space
        // (what `pdfView.convert` yields), `insets(from:)` turns it into CropInsets, `crop` writes
        // them. The OUTPUT crop box — the bounds a viewer displays — must equal the drawn rectangle,
        // on a page that is BOTH rotated 90° AND already cropped to a non-zero origin.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        let startCrop = CGRect(x: 40, y: 55, width: 500, height: 620)
        try PDFFixtures.writePDF(
            markers: [PDFFixtures.marker(1)],
            rotations: [0: 90],
            cropFirstPageTo: startCrop,
            to: src
        )

        // A rectangle the user dragged inside that crop box, in stored page space.
        let selection = CGRect(x: 90, y: 120, width: 300, height: 400)
        let rotation = try PDFFixtures.pageRotations(at: src)[0]
        let insets = PDFToolkit.insets(from: selection, rotation: rotation, in: startCrop)

        let out = dir.url("out.pdf")
        try PDFToolkit.crop(inputURL: src, outputURL: out, insets: insets)

        let outBox = try cropBox(at: out)
        #expect(abs(outBox.minX - selection.minX) < 0.001)
        #expect(abs(outBox.minY - selection.minY) < 0.001)
        #expect(abs(outBox.width - selection.width) < 0.001)
        #expect(abs(outBox.height - selection.height) < 0.001)
        // The rotation still rides along, so the viewer keeps the same orientation.
        #expect(try PDFFixtures.pageRotations(at: out) == [90])
    }

    @Test func marqueeCropRendersOnlyTheDrawnRegion() throws {
        // A green square lands inside the dragged rectangle and a wide margin lands outside it. After
        // cropping to the selection, RENDERING THE OUTPUT'S CROP BOX (what a viewer sees) must show
        // the square and nothing from the trimmed margin — the "open the output and look" check.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        let startCrop = CGRect(x: 40, y: 50, width: 500, height: 600)
        try PDFFixtures.writePDF(
            markers: ["ONLY"],
            cropFirstPageTo: startCrop,
            greenSquareOnFirstPage: CGRect(x: 100, y: 100, width: 60, height: 60),
            to: src
        )

        let selection = CGRect(x: 80, y: 80, width: 200, height: 200)   // contains the green square
        let insets = PDFToolkit.insets(from: selection, rotation: 0, in: startCrop)
        let out = dir.url("out.pdf")
        try PDFToolkit.crop(inputURL: src, outputURL: out, insets: insets)

        let doc = try #require(PDFDocument(url: out))
        let page = try #require(doc.page(at: 0))
        let box = page.bounds(for: .cropBox)
        #expect(box == selection)
        let image = page.thumbnail(of: box.size, for: .cropBox)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let sx = CGFloat(rep.pixelsWide) / box.width
        let sy = CGFloat(rep.pixelsHigh) / box.height
        func color(_ px: CGFloat, _ py: CGFloat) -> NSColor {
            let col = min(rep.pixelsWide - 1, max(0, Int((px - box.minX) * sx)))
            let row = min(rep.pixelsHigh - 1, max(0, Int((box.maxY - py) * sy)))   // flip PDF y-up → image y-down
            return rep.colorAt(x: col, y: row)?.usingColorSpace(.deviceRGB) ?? .white
        }

        // The square (centre ~130,130 in crop-box space) is visibly green in the cropped output…
        let onSquare = color(130, 130)
        #expect(onSquare.greenComponent > 0.5)
        #expect(onSquare.greenComponent - onSquare.redComponent > 0.2)
        // …and a corner well inside the crop but away from the square stayed blank paper.
        let clear = color(260, 260)
        #expect(clear.redComponent > 0.85)
        #expect(clear.greenComponent > 0.85)
        #expect(clear.blueComponent > 0.85)
    }

    // MARK: autoCrop()

    @Test func autoCropWrapsTheRenderedContent() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // One marker line drawn at x=72, baseline y=396, ~24 pt glyphs on a 612×792 page.
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1)], to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.autoCrop(inputURL: src, outputURL: out, padding: 10, unified: false)

        let box = try cropBox(at: out)
        // The box must contain the text region…
        #expect(box.minX <= 72)
        #expect(box.minY <= 396)
        #expect(box.maxY >= 396 + 17)   // cap height of 24 pt system font
        // …and be a dramatic tightening of the full page, top and bottom margins gone.
        #expect(box.height < 120)
        #expect(box.width < 400)
        // The marker text still extracts from the cropped file.
        #expect(try PDFFixtures.pageTexts(at: out) == [PDFFixtures.marker(1)])
    }

    @Test func unifiedAutoCropAppliesOneTrimEverywhere() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1), PDFFixtures.marker(2)], to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.autoCrop(inputURL: src, outputURL: out, padding: 10, unified: true)

        let first = try cropBox(at: out, page: 0)
        let second = try cropBox(at: out, page: 1)
        #expect(first == second)
        #expect(first.height < 120)
    }

    @Test func autoCropHandlesRotatedPages() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // Marker text sits at media-space (72…, ~396) on a page displayed rotated 90°: detection
        // happens in displayed space and must map back through the rotation onto the stored crop
        // rect — the composition insetRect never sees under rotation in the other auto-crop tests.
        try PDFFixtures.writePDF(markers: [PDFFixtures.marker(1)], rotations: [0: 90], to: src)
        let out = dir.url("out.pdf")

        try PDFToolkit.autoCrop(inputURL: src, outputURL: out, padding: 10, unified: false)

        let box = try cropBox(at: out)
        // The stored-space crop must wrap the text's media-space position…
        #expect(box.minX <= 72)
        #expect(box.minY <= 396)
        #expect(box.maxY >= 396 + 17)
        // …and be a tight wrap, not the full page (the line is ~24 pt tall, ~200 pt wide).
        #expect(box.height < 120)
        #expect(box.width < 400)
        // Rotation itself survives the rebuild.
        let doc = try #require(PDFDocument(url: out))
        #expect(try #require(doc.page(at: 0)).rotation == 90)
    }

    @Test func autoCropRefusesToWriteOverTheInput() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.autoCrop(inputURL: src, outputURL: src, padding: 10, unified: true)
        }
        #expect(error?.kind == "outputMatchesInput")
    }

    // MARK: Outline (bookmark) preservation

    @Test func cropPreservesBookmarksPointingAtTheRightPages() throws {
        // Crop rebuilds the document from copied pages, which drops the catalog outline unless it is
        // reattached. Every page is kept in order, so each bookmark must survive AND still resolve to
        // its ORIGINAL page — assert the destination page index, not merely that an outline exists.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            pageCount: 3,
            bookmarks: [("Intro", 0), ("Appendix", 2)],
            to: src
        )
        #expect(try PDFFixtures.outlineBookmarks(at: src).count == 2)   // sanity

        try PDFToolkit.crop(inputURL: src, outputURL: out, insets: CropInsets(top: 10, left: 10, bottom: 10, right: 10))

        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["Intro", "Appendix"])
        #expect(bookmarks.map(\.pageIndex) == [0, 2])
    }

    @Test func autoCropPreservesBookmarksPointingAtTheRightPages() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(
            pageCount: 3,
            bookmarks: [("Intro", 0), ("Appendix", 2)],
            to: src
        )

        try PDFToolkit.autoCrop(inputURL: src, outputURL: out, padding: 10, unified: false)

        let bookmarks = try PDFFixtures.outlineBookmarks(at: out)
        #expect(bookmarks.map(\.label) == ["Intro", "Appendix"])
        #expect(bookmarks.map(\.pageIndex) == [0, 2])
    }

    @Test func cropClampsBookmarkPointsIntoTheTrimmedBox() throws {
        // The fixture points each bookmark at the page's top-left corner (0, height) — OUTSIDE the box
        // once cropping trims it. Reattach must clamp the destination point back inside so the bookmark
        // scrolls to a visible spot, not a blank margin. (The destination PAGE is always correct.)
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, bookmarks: [("Intro", 0)], to: src)

        try PDFToolkit.crop(inputURL: src, outputURL: out,
                            insets: CropInsets(top: 10, left: 20, bottom: 30, right: 40))

        // Still resolves to page 0…
        #expect(try PDFFixtures.outlineBookmarks(at: out).map(\.pageIndex) == [0])

        // …and its point now sits inside the trimmed crop box (origin 20,30 — was 0,792, outside).
        let doc = try #require(PDFDocument(url: out))
        let dest = try #require(doc.outlineRoot?.child(at: 0)?.destination)
        let box = try cropBox(at: out, page: 0)
        let eps: CGFloat = 0.5
        #expect(dest.point.x >= box.minX - eps && dest.point.x <= box.maxX + eps,
                "x \(dest.point.x) outside [\(box.minX), \(box.maxX)]")
        #expect(dest.point.y >= box.minY - eps && dest.point.y <= box.maxY + eps,
                "y \(dest.point.y) outside [\(box.minY), \(box.maxY)]")
        // Prove it actually moved: the original top-edge point (y = 792) was clamped down.
        #expect(dest.point.y < 792)
    }
}
