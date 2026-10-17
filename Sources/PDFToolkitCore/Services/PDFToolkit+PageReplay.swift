import CoreGraphics
import Foundation
import PDFKit

/// One page's geometry as a viewer displays it, resolved once up front.
///
/// The vector rebuild operations — Watermark, Fill & Sign, OCR — all emit pages in *display
/// space*: intrinsic rotation baked upright, the crop box as the page bounds. Each needs the same
/// facts to do it, and each used to re-derive them inline; this is now the one copy.
struct DisplayedPage {
    let page: PDFPage
    let cgPage: CGPDFPage
    /// The source crop box in stored (unrotated) space — for overlays that map their own rects.
    let cropBox: CGRect
    /// Intrinsic rotation, normalized to 0/90/180/270.
    let rotation: Int
    /// The emitted page bounds: origin `.zero`, rotation-normalized displayed size.
    let box: CGRect
    /// Maps upright display space onto the stored page — used to replay the original content, and
    /// by overlays that draw in source space (signature polylines).
    let transform: CGAffineTransform
}

extension PDFToolkit {
    /// The size a viewer shows for a page box under intrinsic rotation — the one copy of the
    /// swap-axes-at-90/270 idiom.
    static func displayedSize(of bounds: CGRect, rotation: Int) -> CGSize {
        let r = normalizedRotation(rotation)
        return (r == 90 || r == 270)
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
    }

    /// Resolves a page's displayed geometry, throwing — never skipping — when the page is
    /// unreadable: silently dropping a page ships an output with fewer pages than the input,
    /// which is data loss dressed up as success. (Locked documents, whose pages all lack a
    /// `pageRef`, are refused earlier by ``openUnlockedDocument(at:)``.)
    ///
    /// Crop box, not media box: it is what viewers display, so the rebuilt page keeps the visible
    /// size. Vector content outside the crop still rides along in the stream — clipped off-page by
    /// the emitted media box, not removed; only rasterizing paths truly destroy it.
    static func displayedPage(_ page: PDFPage?, inputURL: URL) throws -> DisplayedPage {
        guard let page, let cgPage = page.pageRef else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        let cropBox = page.bounds(for: .cropBox)
        // A degenerate (zero/negative) crop box would make the emitted media box zero-size, and
        // `beginDisplayedPage` then silently falls back to a default US-Letter page (see its note),
        // mis-emitting the page. The raster path (`rasterGeometry`) already rejects this; the vector
        // rebuild (Watermark / Fill & Sign / OCR) must too. Malformed-source only.
        guard cropBox.width > 0, cropBox.height > 0 else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        let rotation = normalizedRotation(page.rotation)
        let box = CGRect(origin: .zero, size: displayedSize(of: cropBox, rotation: rotation))
        let transform = cgPage.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: false)
        return DisplayedPage(
            page: page, cgPage: cgPage, cropBox: cropBox, rotation: rotation, box: box, transform: transform
        )
    }

    /// Begins a page of `box` size in a CGPDFContext.
    ///
    /// The media-box value must be **CFData wrapping the CGRect bytes** — a bridged CGRect is
    /// silently ignored, and the context then falls back to its default US Letter page: when this
    /// shipped, every page came out 612×792, clipping content off anything larger (A4's top 50 pt
    /// simply vanished) and padding anything smaller. Owning the wrap here retires that landmine.
    static func beginDisplayedPage(_ ctx: CGContext, box: CGRect) {
        var pageBox = box
        let pageBoxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: pageBoxData] as CFDictionary)
    }

    /// Emits one page the way every vector rebuild does: displayed-size page, original content
    /// replayed upright as vector (text stays selectable), visible annotations flattened in
    /// display space, then the operation's `overlay`.
    ///
    /// The overlay draws in display space — the context's base space here *is* display space, and
    /// annotation drawing maps itself there too (see ``drawAnnotations(of:in:)``). Overlays that
    /// need source space (signature polylines) concatenate `dp.transform` around their own drawing.
    static func emitDisplayedPage(
        _ dp: DisplayedPage,
        into ctx: CGContext,
        overlay: (CGContext, DisplayedPage) -> Void
    ) {
        beginDisplayedPage(ctx, box: dp.box)
        ctx.saveGState()
        ctx.concatenate(dp.transform)
        ctx.drawPDFPage(dp.cgPage)
        ctx.restoreGState()
        drawAnnotations(of: dp.page, in: ctx)
        overlay(ctx, dp)
        ctx.endPDFPage()
    }
}
