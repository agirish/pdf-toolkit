import AppKit
import CoreGraphics
import Foundation
import PDFKit

// Compress: rebuilds pages as JPEG-backed images to shrink file size, either at a fixed
// quality or by binary-searching the quality ladder to hit a target byte budget. Split out
// of PDFToolkit.swift; still `extension PDFToolkit`, so callers are unchanged.
extension PDFToolkit {
    /// Rebuilds the PDF from rendered page images to reduce size. `quality` is 0...1 (JPEG-style tradeoff).
    public static func compress(inputURL: URL, outputURL: URL, quality: Double) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        // Bounded: a write path must never produce a file bigger than its input.
        try writeOutput(try compressDataBounded(inputURL: inputURL, quality: quality), to: outputURL)
    }

    /// In-memory core of ``compress(inputURL:outputURL:quality:)`` — the guarded open plus the
    /// shared page-rebuild loop.
    ///
    /// `onProgress` reports the 1-based page being rebuilt and the total, once per page, so a long
    /// single-file run can drive a determinate bar; `isCancelled` is polled between pages to stop a
    /// multi-second scan promptly (both mirror the OCR engine). Both default to `nil`, so the batch
    /// path and the size-estimate callers compile unchanged.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func compressData(
        inputURL: URL,
        quality: Double,
        onProgress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Data {
        let source = try openUnlockedDocument(at: inputURL)
        return try compressedData(from: source, quality: quality, onProgress: onProgress, isCancelled: isCancelled)
    }

    /// ``compressData(inputURL:quality:onProgress:isCancelled:)`` bounded by the input's size — the
    /// variant every path that actually WRITES a file uses. The bound has a margin
    /// (`worthwhileCompressionRatio`): a result that isn't meaningfully smaller is not worth the
    /// quality it costs, so the source passes through instead.
    ///
    /// Rasterizing a lean vector/text PDF can *inflate* it, so quality mode could hand back a
    /// "compressed" file larger than the original. `compressToTargetData` has always had this
    /// fallback; quality mode did not, because the Compress screen's strength-estimate cards call
    /// the raw core directly and a guard there would collapse them all onto the source size (they
    /// exist to show how the rungs differ). Keeping the bound in a separate save-only wrapper gives
    /// both: honest per-rung estimates on screen, and an output that is never bigger than the input.
    ///
    /// The estimate cards can therefore quote a size the save doesn't produce — only ever in the
    /// direction of the saved file being *smaller* (the source passed through), which is also what
    /// the screen's "Already optimized" wording covers.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func compressDataBounded(
        inputURL: URL,
        quality: Double,
        onProgress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Data {
        let compressed = try compressData(
            inputURL: inputURL, quality: quality, onProgress: onProgress, isCancelled: isCancelled
        )
        // The count, not the bytes: the source is only read when it actually wins.
        guard let sourceBytes = try? inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              compressed.count >= Int(Double(sourceBytes) * worthwhileCompressionRatio),
              let original = try? Data(contentsOf: inputURL)
        else { return compressed }
        return original
    }

    /// How much smaller a rasterized result must be for the save to be worth taking: it has to come
    /// in under this fraction of the source, i.e. save at least 5%.
    ///
    /// A bare "never bigger than the input" bound isn't enough. A 600-dpi JPEG2000 scan re-encoded at
    /// the top of the quality range measured 0.3% smaller than its source (1,852,933 vs 1,858,059
    /// bytes) — a full rasterization that threw away more than half the linear resolution and bought
    /// nothing. Under that bound it saved anyway, silently degrading the file. Anything inside this
    /// margin now keeps the ORIGINAL bytes, which the screen already reports honestly as "Already
    /// optimized" (output == input, so `shrank` is false).
    ///
    /// Only the save path is bounded — the strength cards call the unbounded core, so their estimates
    /// still show what each rung would actually produce rather than collapsing onto the source size.
    private static let worthwhileCompressionRatio = 0.95

    /// Compresses toward a byte budget by sweeping a bounded ladder of qualities from high to low,
    /// stopping at the first that lands under `targetBytes`. Writes the best attempt: the highest
    /// quality that fits, or — when even the lowest quality overshoots — the smallest file produced,
    /// so an unreachable target still yields the most-compressed result rather than an error.
    ///
    /// The sweep rebuilds the document a handful of times at most (the ladder is short), trading a
    /// few extra rasterizations for a size the caller can actually promise. ``compressToTargetData``
    /// binary-searches the quality ladder for the highest rung that fits, falling back to the smallest
    /// result when none do; its end-to-end behavior is pinned by `PDFToolkitCompressTargetTests`.
    static func compressToTarget(inputURL: URL, outputURL: URL, targetBytes: Int) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        guard let sourceBytes = try? inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }

        // Already at or under the target: keep the cheap on-disk copy instead of pulling the whole
        // source through memory just to write it back out.
        if sourceBytes <= targetBytes {
            // Guarded open before the pass-through, so a locked file errors clearly instead of
            // being copied under a "-compressed" name when it happens to fit the target.
            _ = try openUnlockedDocument(at: inputURL)
            do {
                try? FileManager.default.removeItem(at: outputURL)
                try FileManager.default.copyItem(at: inputURL, to: outputURL)
            } catch {
                throw PDFOperationError.couldNotWrite(outputURL)
            }
            return
        }

        try writeOutput(try compressToTargetData(inputURL: inputURL, targetBytes: targetBytes), to: outputURL)
    }

    /// In-memory core of ``compressToTarget(inputURL:outputURL:targetBytes:)`` — the quality-ladder
    /// sweep. A source that already fits the target passes through as its own unchanged bytes.
    ///
    /// `onProgress`/`isCancelled` (defaulted `nil`, so existing callers are unchanged) thread straight
    /// into each ladder rung's page loop: progress is reported per page *within the current pass* — a
    /// lower rung simply re-reports 1…total — which is enough to keep the bar moving without inventing
    /// multi-pass math, and cancellation is honored between pages exactly as in ``compressData``.
    /// - Returns: The new file's bytes. Writes nothing; the caller decides where they go.
    public static func compressToTargetData(
        inputURL: URL,
        targetBytes: Int,
        onProgress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Data {
        // The byte count, not the bytes: pinning the whole source Data across a multi-rung sweep
        // doubled peak memory on exactly the scan-heavy files this operation exists for. The full
        // bytes are read only in the rare inflation fallback at the end.
        guard let sourceBytes = try? inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PDFOperationError.couldNotOpen(inputURL)
        }
        // Guarded open before the pass-through below, so a locked file errors clearly instead of
        // being handed back under a "-compressed" name when it happens to fit the target.
        let source = try openUnlockedDocument(at: inputURL)

        // Already at or under the target: rasterizing can only lose quality, so pass the source
        // through unchanged instead of walking the ladder for a worse, possibly larger file.
        if sourceBytes <= targetBytes {
            do {
                return try Data(contentsOf: inputURL)
            } catch {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
        }

        // Attempt size is monotone in quality (a lower rung rasterizes fewer pixels), so binary-
        // search the ladder for the highest rung that fits: at most 3 rebuilds instead of walking
        // up to all 6. Memory holds at most one fitting payload OR the running smallest — once any
        // rung fits, the smallest-so-far fallback can never be needed and is released.
        let ladder: [Double] = [0.9, 0.75, 0.6, 0.45, 0.3, 0.2]
        var fittingBest: Data?
        var smallest: Data?
        var lo = 0
        var hi = ladder.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            // Per-attempt pool: each rung rebuilds the whole document; its scratch must not stack
            // across rungs. The returned Data survives the drain — it's retained, not autoreleased.
            let data = try autoreleasepool {
                try compressedData(from: source, quality: ladder[mid], onProgress: onProgress, isCancelled: isCancelled)
            }
            if data.count <= targetBytes {
                fittingBest = data      // fits — hunt a higher-quality rung
                smallest = nil
                hi = mid - 1
            } else {
                if fittingBest == nil, data.count < (smallest?.count ?? .max) {
                    smallest = data
                }
                lo = mid + 1
            }
        }

        guard var chosen = fittingBest ?? smallest else {
            throw PDFOperationError.compressionFailed
        }
        // Rasterizing a lean vector/text PDF can *inflate* it past every rung. Never hand back a
        // "compressed" file bigger than the original — fall back to the source bytes, so the
        // output is bounded by the input even when the target is unreachable.
        //
        // When no rung fit at all, the same "not worth it" margin as the quality path applies: a
        // result that misses the target AND barely undercuts the source is a pure quality loss, so
        // keep the original. A rung that *did* fit is exempt — the user named a byte budget, and
        // handing back a larger original because the budget was only a few percent under the source
        // would ignore the request they actually made.
        let floorBytes = fittingBest == nil ? Int(Double(sourceBytes) * worthwhileCompressionRatio) : sourceBytes
        if chosen.count >= floorBytes {
            do {
                chosen = try Data(contentsOf: inputURL)
            } catch {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
        }

        return chosen
    }

    /// JPEG factor for rebuilt compress pages, driven by the quality lever. The top of the range stays
    /// at 0.85 — the value calibrated to what `PDFPage(image:)` (the previous path) effectively encoded
    /// at, so highest-quality output holds the historical size curve (a photo-class bitmap through
    /// PDFPage(image:) landed within ~8% of an explicit 0.85 encode, probed) — and eases down to ~0.33
    /// at the bottom.
    ///
    /// Encoding quality is deliberately a *second* size lever alongside raster resolution
    /// (`compressedPageDPI`): the two move together so the rungs stay well separated in size, and so
    /// a page that is already at its native resolution — where the DPI lever is capped out and does
    /// nothing — still gets smaller as the user asks for more compression.
    private static func compressedPageJPEGFactor(for quality: Double) -> Double {
        min(0.85, max(0.3, 0.30 + 0.55 * quality))
    }

    /// Raster resolution, in DPI, for a rebuilt page at `quality`.
    ///
    /// Compression used to cap the raster at 1 pixel per PDF point — 72 dpi — for every page whose
    /// long edge fell under the quality's pixel budget, which is every ordinary page size. A 600-dpi
    /// scan therefore came back at 72 dpi at *every* setting, including the highest, and the quality
    /// lever only changed how hard that already-destroyed bitmap was JPEG'd. Text at 72 dpi is mush.
    ///
    /// Resolution is now the primary lever and is expressed in the unit that actually governs
    /// legibility: 225 dpi at the top (comfortably sharp text), easing to ~110 dpi at the bottom,
    /// where a page is still readable but small. `PDFToolkitCompressResolutionTests` pins that the
    /// top of the range renders a 613 × 868 pt page well above its point size.
    private static func compressedPageDPI(for quality: Double) -> CGFloat {
        72 + 180 * CGFloat(min(1, max(0, quality)))
    }

    /// Absolute pixel ceiling for a rebuilt page's long edge, so an oversized page (a poster, a
    /// plotter sheet) can't turn a DPI target into a gigapixel render. Ordinary page sizes are far
    /// below this at every quality — a Letter page at 225 dpi is ~2475 px.
    private static let compressedPageMaxPixel: CGFloat = 5000

    /// The page's own image resolution in pixels per point, if it is image-backed — the ceiling
    /// past which rendering bigger adds bytes but no detail.
    ///
    /// A 72-dpi scan asked for 225 dpi would triple in size to re-encode pixels that were never
    /// there. Enumerates the page's image XObjects (nested form XObjects are not walked — an
    /// unrecognized page simply gets no cap, which is the pre-existing behavior) and reports the
    /// largest against the page's long edge. `nil` means "no image found": vector/text pages have
    /// no native resolution and are rendered at the full DPI target, which is where the extra
    /// resolution pays off most.
    private static func nativePixelsPerPoint(of cgPage: CGPDFPage, longestPointEdge: CGFloat) -> CGFloat? {
        guard longestPointEdge > 0,
              let pageDict = cgPage.dictionary
        else { return nil }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources else { return nil }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return nil }

        // CGPDFDictionaryApplyFunction hands each entry to a C function, so the running maximum
        // travels through an unmanaged box rather than a capturing closure.
        final class Box { var maxPixels: CGFloat = 0 }
        let box = Box()
        CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream)
            else { return }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image"
            else { return }
            var width: CGPDFInteger = 0
            var height: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(dict, "Width", &width),
                  CGPDFDictionaryGetInteger(dict, "Height", &height)
            else { return }
            box.maxPixels = max(box.maxPixels, CGFloat(max(width, height)))
        }, Unmanaged.passUnretained(box).toOpaque())

        guard box.maxPixels > 0 else { return nil }
        return box.maxPixels / longestPointEdge
    }

    /// Rebuilds every page as a bitmap at the resolution implied by `quality` and returns the new PDF
    /// as in-memory `Data`. Shared by `compress` (writes it once) and `compressToTarget` (measures the
    /// size at several qualities before writing the best one) so the page-rebuild loop lives in one place.
    ///
    /// **Streamed**: each page's JPEG bytes flow into the growing output as they're produced, so
    /// peak memory is one page's render/encode scratch plus the compressed output — not every page
    /// bitmap pinned in a `PDFDocument` until a final serialization, which peaked at gigabytes on
    /// long scans. CGPDFContext embeds a JPEG-sourced CGImage as its original DCT data (probed:
    /// a 579 KB JPEG emitted a 583 KB page), so this is `PDFPage(image:)`'s encoding made explicit.
    private static func compressedData(
        from source: PDFDocument,
        quality: Double,
        onProgress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Data {
        let q = min(1, max(0.05, quality))
        let targetScale = compressedPageDPI(for: q) / 72

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.compressionFailed
        }

        var emitted = 0
        for i in 0..<source.pageCount {
            // Report the page about to be rebuilt, then bail before its (expensive) render if the run
            // was cancelled — same order as the OCR engine, so a cancelled compress stops promptly
            // between pages and surfaces as a `CancellationError`.
            onProgress?(i + 1, source.pageCount)
            if isCancelled?() == true { throw CancellationError() }
            // Per-page pool: the render bitmap, its rep, and the JPEG bytes are all page-sized
            // transients — drained page by page, only the compressed stream accumulates.
            try autoreleasepool {
                guard let page = source.page(at: i), let cgPage = page.pageRef else {
                    // A page we can't reach (nil page/pageRef) must fail loudly, not vanish: the old
                    // `return` skipped it, so the output silently came out with fewer pages than the
                    // input, caught only by the coarse `emitted > 0` backstop. Match the render-failure
                    // guard right below and throw, so a page that can't be rebuilt is an error.
                    throw PDFOperationError.compressionFailed
                }
                // Resolution budget for this page: the quality's DPI target, held under the page's
                // own native image resolution (no bytes spent re-encoding detail the source never
                // had) and under the absolute pixel ceiling. `rasterGeometry` divides the budget by
                // the long edge, so handing it a pixel count is how a scale is requested; upscaling
                // past 1 px/pt is exactly the point here, so `allowUpscale` is on.
                let longest = max(page.bounds(for: .cropBox).width, page.bounds(for: .cropBox).height)
                let nativeScale = nativePixelsPerPoint(of: cgPage, longestPointEdge: longest)
                let scale = min(targetScale, nativeScale ?? targetScale)
                let maxPixel = min(longest * scale, compressedPageMaxPixel)
                guard
                    let geometry = rasterGeometry(for: page, maxPixelDimension: maxPixel, allowUpscale: true),
                    let bitmap = renderBitmap(page, cgPage: cgPage, geometry: geometry, redactionFills: []),
                    let jpeg = NSBitmapImageRep(cgImage: bitmap)
                        .representation(using: .jpeg, properties: [.compressionFactor: compressedPageJPEGFactor(for: q)]),
                    let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
                    let jpegImage = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)
                else {
                    throw PDFOperationError.compressionFailed
                }
                // The bitmap is the page as *displayed* (rotation applied, crop box), so the
                // emitted page uses that size — the raw media box would letterbox rotated pages,
                // and no PDFPage.rotation is re-applied on top.
                let box = CGRect(origin: .zero, size: geometry.displaySize)
                beginDisplayedPage(ctx, box: box)
                ctx.interpolationQuality = .high
                ctx.draw(jpegImage, in: box)
                ctx.endPDFPage()
                emitted += 1
            }
        }
        ctx.closePDF()

        guard emitted > 0, pdfData.length > 0 else {
            throw PDFOperationError.compressionFailed
        }
        // Pages are rasterized, but the catalog needn't be: bookmarks, the info dictionary, and
        // links survive compression. Each page keeps its displayed geometry, so link rects still
        // land on the same content.
        return PDFToolkit.restoringCatalog(pdfData as Data, from: source, restoreLinks: true)
    }
}
