import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// The paper each image lands on. `matchImage` sizes every page to its own image (one pixel = one
/// point), so nothing is cropped or letterboxed; the fixed sizes flip to landscape automatically
/// when the image is wider than tall.
public enum ImagePageSize: String, CaseIterable, Sendable {
    case matchImage
    case a4
    case usLetter

    public var label: String {
        switch self {
        case .matchImage: return "Auto (match image)"
        case .a4: return "A4"
        case .usLetter: return "US Letter"
        }
    }

    /// Portrait page size in points, or nil for `matchImage`.
    var portraitSize: CGSize? {
        switch self {
        case .matchImage: return nil
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .usLetter: return CGSize(width: 612, height: 792)
        }
    }
}

/// How the images are placed. RGB-free plain values so the options cross the PDF serial queue.
public struct ImagesToPDFOptions: Sendable {
    var pageSize: ImagePageSize = .matchImage
    /// On a fixed page size: false = fit (whole image visible, centered), true = fill (cover the
    /// page edge to edge, cropping the overflow). Ignored for `matchImage`, which is always exact.
    var fillsPage: Bool = false

    /// The memberwise initializer, spelled out so it can be public.
    public init(pageSize: ImagePageSize = .matchImage, fillsPage: Bool = false) {
        self.pageSize = pageSize
        self.fillsPage = fillsPage
    }
}

extension PDFToolkit {
    /// The PDF spec's media-box ceiling (200in × 72pt); `matchImage` pages scale down to stay legal.
    private static let maxPagePoints: CGFloat = 14400

    /// Combines images into one PDF, a page per image, in the order given.
    static func imagesToPDF(inputURLs: [URL], outputURL: URL, options: ImagesToPDFOptions) throws {
        try requireDistinctOutput(outputURL, from: inputURLs)
        try writeOutput(try imagesToPDFData(inputURLs: inputURLs, options: options), to: outputURL)
    }

    /// In-memory core of ``imagesToPDF(inputURLs:outputURL:options:)``.
    ///
    /// Every image is loaded through ImageIO with its EXIF orientation baked in (a sideways iPhone
    /// HEIC comes out upright), then drawn into a CGPDFContext page. Fixed page sizes auto-rotate
    /// to landscape for landscape images so photos aren't needlessly letterboxed.
    public static func imagesToPDFData(inputURLs: [URL], options: ImagesToPDFOptions) throws -> Data {
        guard !inputURLs.isEmpty else { throw PDFOperationError.noInputFiles }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.couldNotEncodeOutput
        }

        for url in inputURLs {
            let image = try orientedImage(at: url)
            let imageSize = CGSize(width: image.width, height: image.height)
            let box = pageBox(for: imageSize, options: options)

            beginDisplayedPage(ctx, box: box)
            ctx.saveGState()
            if options.pageSize != .matchImage, options.fillsPage {
                ctx.clip(to: box)
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: drawRect(imageSize: imageSize, in: box, options: options))
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.couldNotEncodeOutput }
        return pdfData as Data
    }

    /// Displayed pixel sizes for the queued images, keyed by path — header reads only, no bitmaps.
    ///
    /// Deliberately NOT `PDFBackgroundWork`: this is pure ImageIO with no PDFKit object in sight,
    /// and running a big image queue on the single PDF serial queue starved every tool's page
    /// previews behind it. Nonisolated async runs on the global concurrent executor (off the main
    /// actor); cancellation is honored between files (the partial result is discarded by the
    /// caller's own cancellation guard).
    public static func imagePixelSizes(for urls: [URL]) async -> [String: CGSize] {
        var sizes: [String: CGSize] = [:]
        for url in urls {
            if Task.isCancelled { break }
            if let size = (try? url.withSecurityScopedAccess { imagePixelSize(at: url) }) ?? nil {
                sizes[url.path] = size
            }
        }
        return sizes
    }

    /// One image's preview render for a demand-loaded grid cell — orientation-correct, nil when
    /// the file isn't a readable image. Nonisolated async so the ImageIO decode runs off the main
    /// actor (and never touches the PDF serial queue, which pure image work has no business on);
    /// the pool drains the decode scratch with the call.
    public static func imagePreview(at url: URL) async -> NSImage? {
        autoreleasepool {
            (try? url.withSecurityScopedAccess { imageThumbnail(at: url) }) ?? nil
        }
    }

    /// A small, orientation-correct preview of an image for the tool's page list — nil when the
    /// file isn't a readable image. Runs ImageIO directly, so call it off the main thread.
    static func imageThumbnail(at url: URL, maxPixelSize: CGFloat = 400) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The displayed (orientation-applied) pixel size of an image, or nil if unreadable.
    static func imagePixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        // EXIF orientations 5–8 swap the displayed axes.
        if let raw = props[kCGImagePropertyOrientation] as? UInt32, raw >= 5, raw <= 8 {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    /// Loads the image with its EXIF orientation applied, at full resolution.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` with `…WithTransform` is the one ImageIO path that
    /// hands back a pre-rotated bitmap; `…MaxPixelSize` set to the true long edge keeps it
    /// full-size. Plain `CreateImageAtIndex` would return the sensor-oriented pixels and sideways
    /// iPhone photos.
    private static func orientedImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else {
            throw PDFOperationError.couldNotOpenImage(url)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw PDFOperationError.couldNotOpenImage(url)
        }
        return image
    }

    /// The page rectangle for one image under the chosen sizing.
    private static func pageBox(for imageSize: CGSize, options: ImagesToPDFOptions) -> CGRect {
        guard let portrait = options.pageSize.portraitSize else {
            // Match the image: one pixel = one point, scaled down only if it would exceed the
            // PDF spec's 14 400-pt media-box ceiling.
            let longest = max(imageSize.width, imageSize.height, 1)
            let scale = min(1, maxPagePoints / longest)
            return CGRect(origin: .zero,
                          size: CGSize(width: max(1, imageSize.width * scale),
                                       height: max(1, imageSize.height * scale)))
        }
        let landscape = imageSize.width > imageSize.height
        let size = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        return CGRect(origin: .zero, size: size)
    }

    /// Where the image lands on the page: exact for `matchImage`, aspect-fit centered, or
    /// aspect-fill centered (caller clips to the page).
    private static func drawRect(imageSize: CGSize, in box: CGRect, options: ImagesToPDFOptions) -> CGRect {
        guard options.pageSize != .matchImage else { return box }
        guard imageSize.width > 0, imageSize.height > 0 else { return box }
        let scaleFit = min(box.width / imageSize.width, box.height / imageSize.height)
        let scaleFill = max(box.width / imageSize.width, box.height / imageSize.height)
        let scale = options.fillsPage ? scaleFill : scaleFit
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: box.midX - size.width / 2,
            y: box.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
