import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The watermark stamp helpers: which pages get the mark, how text and logo images are drawn into a
/// page's display space, and how a picked logo file is decoded. Split out of ``PDFToolkit`` so the
/// text/image/font/page-scope additions live next to each other rather than swelling the already
/// large `PDFToolkit.swift`. The core (`watermarkData`) stays there and calls into these.
extension PDFToolkit {

    // MARK: - Page scope

    /// The zero-based page indices a ``WatermarkOptions/PageScope`` selects for a `pageCount`-page
    /// document, as a `Set` so the per-page "is this page stamped?" check is O(1). Resolved per
    /// document (not pre-expanded in the options) so a custom range stays correct file-by-file in a
    /// batch and overshooting throws `pageOutOfBounds` exactly like the other range-taking tools.
    static func applicableWatermarkPages(_ scope: WatermarkOptions.PageScope, pageCount: Int) throws -> Set<Int> {
        switch scope {
        case .all:
            return Set(0..<pageCount)
        case .firstPageOnly:
            return pageCount > 0 ? [0] : []
        case .custom(let text):
            // The user explicitly chose "Custom range": an empty field is an error, not a silent
            // "all pages" — the same contract Rotate and Delete use for their range fields.
            return Set(try PageRangeParser.parse(text, pageCount: pageCount, emptyMeansAllPages: false))
        }
    }

    // MARK: - Stamp dispatch

    /// Draws the watermark for one page in *display space* (the emit context's base space): text via
    /// CoreText, or a logo via `CGContext.draw`. `trimmedText` is the already-trimmed string so the
    /// text branch stamps exactly what the empty-text guard validated.
    static func drawWatermark(in ctx: CGContext, box: CGRect, trimmedText: String, options: WatermarkOptions) {
        switch options.content {
        case .text:
            drawTextWatermark(in: ctx, box: box, text: trimmedText, options: options)
        case .image:
            guard let image = options.image?.cgImage else { return }
            drawImageWatermark(image, in: ctx, box: box, options: options)
        }
    }

    // MARK: - Text

    private static func drawTextWatermark(in ctx: CGContext, box: CGRect, text: String, options: WatermarkOptions) {
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let color = NSColor(
            srgbRed: options.red,
            green: options.green,
            blue: options.blue,
            alpha: max(0, min(1, options.opacity))
        )
        let font = watermarkFont(named: options.fontName, size: max(4, options.fontSize))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let radians = options.rotationDegrees * .pi / 180

        ctx.saveGState()
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: radians)

        if options.tiled {
            // Cover the page after rotation: step over a square whose side is the page diagonal.
            let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
            let stepX = textSize.width + 100
            let stepY = textSize.height + 100
            var y = -diagonal / 2
            while y <= diagonal / 2 {
                var x = -diagonal / 2
                while x <= diagonal / 2 {
                    string.draw(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
            }
        } else {
            string.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
        }

        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Resolves the text-watermark font. No chosen family means the bold system font — the original
    /// default, so untouched text watermarks look identical. A chosen family that isn't itself a
    /// valid PostScript font name is resolved through the font manager; anything unresolved falls
    /// back to the bold system font rather than silently dropping the stamp.
    public static func watermarkFont(named name: String?, size: CGFloat) -> NSFont {
        guard let name, !name.isEmpty else { return .boldSystemFont(ofSize: size) }
        if let font = NSFont(name: name, size: size) { return font }
        if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) {
            return font
        }
        return .boldSystemFont(ofSize: size)
    }

    // MARK: - Image

    private static func drawImageWatermark(_ image: CGImage, in ctx: CGContext, box: CGRect, options: WatermarkOptions) {
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0, box.width > 0, box.height > 0 else { return }

        // Aspect-fit the logo inside a scale-fraction of the page so it never overflows the edges.
        let scale = max(0.02, min(1, options.imageScale))
        let fit = min(box.width * scale / imgW, box.height * scale / imgH)
        let size = CGSize(width: imgW * fit, height: imgH * fit)
        let radians = options.rotationDegrees * .pi / 180

        ctx.saveGState()
        // Global alpha multiplies the logo's own per-pixel alpha, so a transparent PNG keeps its
        // cutout AND fades to the chosen opacity (rather than stamping an opaque rectangle).
        ctx.setAlpha(max(0, min(1, options.opacity)))
        ctx.interpolationQuality = .high
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: radians)

        if options.tiled {
            let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
            let stepX = size.width + 60
            let stepY = size.height + 60
            var y = -diagonal / 2
            while y <= diagonal / 2 {
                var x = -diagonal / 2
                while x <= diagonal / 2 {
                    ctx.draw(image, in: CGRect(x: x, y: y, width: size.width, height: size.height))
                    x += stepX
                }
                y += stepY
            }
        } else {
            ctx.draw(image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
        ctx.restoreGState()
    }

    // MARK: - Logo decode (called from the view before the options cross the serial queue)

    /// Decodes a picked logo into a watermark-ready `CGImage`: a raster image (PNG/JPG/HEIC/…) via
    /// ImageIO with EXIF orientation baked in, or the first page of a PDF logo rasterized on a
    /// transparent background. Wraps its own security scope; returns `nil` when the file isn't a
    /// readable image or PDF. Runs ImageIO/PDFKit directly, so call it off the main thread (and, for
    /// the PDF branch, on the shared serial queue — PDFKit is not thread-safe).
    public static func watermarkImageSource(at url: URL) -> WatermarkImage? {
        let cg = (try? url.withSecurityScopedAccess { () -> CGImage? in
            isPDF(url) ? firstPageImage(ofPDFAt: url) : orientedRasterImage(at: url)
        }) ?? nil
        return cg.map(WatermarkImage.init(cgImage:))
    }

    private static func isPDF(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    /// Full-resolution, EXIF-orientation-applied decode that preserves the alpha channel. Drawing
    /// into a premultiplied-alpha bitmap normalizes every source (indexed PNGs, grayscale, CMYK
    /// JPEGs) into one straight-alpha RGBA image, so the transparency and orientation are both
    /// correct before the logo is ever stamped.
    private static func orientedRasterImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let base = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            .flatMap { $0[kCGImagePropertyOrientation] as? UInt32 } ?? 1
        return redrawUpright(base, orientation: orientation)
    }

    /// The largest side, in pixels, a decoded raster logo is kept at. A watermark is only ever
    /// aspect-fit into a fraction of a page and often tiled/faded, so a 48MP phone photo carried at
    /// full resolution would bloat the by-value ``WatermarkOptions`` batch snapshot (~190MB) and be
    /// redrawn per page and per tile for no visible gain. Capping the uprighted output here keeps a
    /// logo crisp for print (well above 300 dpi at any sane on-page size) while bounding it to ~16MB.
    private static let maxUprightRasterDimension = 2000

    /// Redraws `image` upright (per its EXIF orientation) into a fresh premultiplied-alpha RGBA
    /// bitmap, downscaled so its longest side fits ``maxUprightRasterDimension``. Orientations 5–8
    /// swap the displayed axes.
    private static func redrawUpright(_ image: CGImage, orientation: UInt32) -> CGImage? {
        let w = image.width, h = image.height
        let swapsAxes = orientation >= 5 && orientation <= 8
        // The upright logical size (source axes, swapped for 5–8) before any downscale.
        let uprightW = swapsAxes ? h : w
        let uprightH = swapsAxes ? w : h
        guard uprightW > 0, uprightH > 0 else { return nil }

        // Fit the longest upright side to the cap; the bitmap is allocated at the capped size so the
        // full-resolution source is never materialized as an intermediate.
        let fit = min(1, CGFloat(maxUprightRasterDimension) / CGFloat(max(uprightW, uprightH)))
        let outW = max(1, Int((CGFloat(uprightW) * fit).rounded()))
        let outH = max(1, Int((CGFloat(uprightH) * fit).rounded()))
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        // Scale the capped bitmap up to the upright logical size, apply the EXIF transform (expressed
        // in that logical space), then draw the sensor pixels into the unit rect it describes.
        ctx.scaleBy(x: CGFloat(outW) / CGFloat(uprightW), y: CGFloat(outH) / CGFloat(uprightH))
        ctx.concatenate(orientationTransform(orientation, width: CGFloat(w), height: CGFloat(h), outW: CGFloat(uprightW), outH: CGFloat(uprightH)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The affine transform that, applied to a bottom-left-origin context of size `outW × outH`,
    /// makes a `width × height` sensor-oriented image draw upright. Covers all 8 EXIF orientations.
    private static func orientationTransform(_ orientation: UInt32, width: CGFloat, height: CGFloat, outW: CGFloat, outH: CGFloat) -> CGAffineTransform {
        // CoreGraphics contexts are y-up; EXIF orientation is described top-down. These map each
        // case into the y-up context. 1 = up (identity). 3 = 180°. 6/8 = 90° rotations. 2/4/5/7 add
        // a mirror. Derived so the drawn image fills [0,0,width,height] correctly post-transform, and
        // verified pairwise against Apple's own baking (`CGImageSourceCreateThumbnailAtIndex` with
        // `kCGImageSourceCreateThumbnailWithTransform`) for all eight orientations.
        switch orientation {
        case 2: // mirrored horizontal
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: // 180°
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: // mirrored vertical
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: // mirrored horizontal, 90° CCW = transpose  (axes swap: out is height×width)
            return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 6: // 90° CW (the common portrait-phone capture)
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 7: // mirrored horizontal, 90° CW = transverse
            return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: // 90° CCW
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: // 1 = up
            return .identity
        }
    }

    /// Rasterizes the first page of a PDF logo onto a transparent bitmap so a vector logo can be
    /// stamped like any image, honoring its intrinsic rotation and crop box.
    private static func firstPageImage(ofPDFAt url: URL) -> CGImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0), let cgPage = page.pageRef else {
            return nil
        }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Displayed size (axes swapped for a /Rotate 90|270 logo page) so a rotated logo isn't drawn
        // into a wrong-aspect bitmap and clipped/squashed. The old path used the raw crop-box size and
        // `page.draw`, which ignored intrinsic rotation.
        let displayed = displayedSize(of: bounds, rotation: page.rotation)
        // ~2× the point size keeps a stamped logo crisp without producing an enormous bitmap.
        let scale: CGFloat = 2
        let pxW = Int((displayed.width * scale).rounded())
        let pxH = Int((displayed.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(
                data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // `getDrawingTransform(.cropBox)` maps the crop box upright into the displayed-size rect
        // (rotation applied, crop origin subtracted) — the same proven raster path redaction/compress
        // use — so a rotated or non-zero-origin logo page lands correctly on the transparent bitmap.
        let transform = cgPage.getDrawingTransform(
            .cropBox, rect: CGRect(origin: .zero, size: displayed), rotate: 0, preserveAspectRatio: true
        )
        ctx.concatenate(transform)
        ctx.drawPDFPage(cgPage)
        return ctx.makeImage()
    }
}
