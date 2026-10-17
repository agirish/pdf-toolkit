import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Per-edge trim amounts in *displayed* points — top is the top the user sees, regardless of the
/// page's intrinsic rotation. Plain values so they cross the PDF serial queue.
public struct CropInsets: Equatable, Sendable {
    public var top: CGFloat = 0
    public var left: CGFloat = 0
    public var bottom: CGFloat = 0
    public var right: CGFloat = 0

    /// The memberwise initializer, spelled out so it can be public.
    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }

    /// Element-wise minimum — the largest trim that is safe on every page (unified auto-crop).
    static func elementWiseMin(_ a: CropInsets, _ b: CropInsets) -> CropInsets {
        CropInsets(top: min(a.top, b.top), left: min(a.left, b.left),
                   bottom: min(a.bottom, b.bottom), right: min(a.right, b.right))
    }
}

extension PDFToolkit {
    /// No crop may leave less than this per axis — a sliver page is unusable in every viewer.
    public static let minimumCropSide: CGFloat = 24

    /// Insets the crop box of every page — or only `pageIndices` when given — by the displayed-edge
    /// amounts and writes a new PDF.
    static func crop(inputURL: URL, outputURL: URL, insets: CropInsets, pageIndices: Set<Int>? = nil) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try cropData(inputURL: inputURL, insets: insets, pageIndices: pageIndices), to: outputURL)
    }

    /// In-memory core of ``crop(inputURL:outputURL:insets:pageIndices:)``.
    ///
    /// The crop box is what viewers display; page content is not deleted, so cropping back out
    /// remains possible in any PDF editor. Insets are given in *displayed* orientation and mapped
    /// through each page's intrinsic rotation onto the stored (unrotated) crop rect — trimming
    /// "the top you see" of a rotation-90 page moves the stored box's minX edge, not maxY.
    ///
    /// `pageIndices` nil trims every page (the segmented "Custom margins" and "Auto-detect" paths);
    /// a set trims only those 0-based pages and copies the rest untouched — the marquee's
    /// "this page only" option, where the drawn box is exact on one page but arbitrary on others.
    public static func cropData(inputURL: URL, insets: CropInsets, pageIndices: Set<Int>? = nil) throws -> Data {
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let output = PDFDocument()
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i), let copy = page.copy() as? PDFPage else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            if pageIndices?.contains(i) ?? true {
                let current = page.bounds(for: .cropBox)
                let cropped = insetRect(current, rotation: page.rotation, by: insets)
                guard cropped.width >= minimumCropSide, cropped.height >= minimumCropSide else {
                    throw PDFOperationError.cropTooSmall(pageNumber: i + 1)
                }
                copy.setBounds(cropped, for: .cropBox)
            }
            output.insert(copy, at: output.pageCount)
        }
        reattachOutline(from: source, to: output)
        remapInternalLinksOfFullCopy(from: source, to: output)
        carryDocumentAttributes(from: source, to: output)
        guard let data = output.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// Carries the source's outline (bookmarks) onto a rebuilt `output` that copied EVERY page in the
    /// SAME order (crop / auto-crop). The bookmarks live on the catalog, so the page-copy rebuild
    /// drops them unless reattached. Every page is 1:1 and in order, so each bookmark resolves to the
    /// right page — but cropping SHRINKS the page box, and a stored destination point (often the
    /// page's top edge) can then fall OUTSIDE the trimmed box, scrolling a bookmark to a blank margin
    /// in viewers that don't clamp. Rebuild each destination on the matching output page with its
    /// point clamped into that page's new crop box, so the bookmark lands on a visible spot. A node
    /// with no resolvable destination keeps its label + children; if it carried a non-GoTo *action*
    /// (a web link, the common "open a URL" bookmark) that action is carried across too — dropping
    /// it would silently turn a working link into dead label text. Subset/reorder paths remap
    /// differently (see `PDFToolkit.remapOutline`).
    ///
    /// - Parameter mappingPoint: converts a source destination point on the given page index into
    ///   the output page's space. Identity for the crop paths, which copy pages whole and keep their
    ///   `/Rotate`. The catalog-restore path passes a display-space mapping instead, because its
    ///   rebuilt pages are emitted upright with rotation flattened — the same mapping the link
    ///   bounds go through in `sourceLinks`. Without it, every bookmark into a rotated page lands at
    ///   the wrong spot (or off the page).
    ///
    /// An interactive `/AcroForm` is not restored by this copy-and-rebuild — out of scope here.
    static func reattachOutline(
        from source: PDFDocument,
        to output: PDFDocument,
        mappingPoint: (Int, CGPoint) -> CGPoint = { _, point in point }
    ) {
        guard let sourceRoot = source.outlineRoot else { return }

        func rebuild(_ node: PDFOutline, into parent: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let kept = PDFOutline()
                kept.label = child.label
                if let dest = child.destination, let destPage = dest.page {
                    let index = source.index(for: destPage)
                    if index != NSNotFound, let outPage = output.page(at: index) {
                        let box = outPage.bounds(for: .cropBox)
                        // A "Fit"-style destination carries the unspecified sentinel in one or both
                        // coordinates; mixing that through a rotation mapping (which swaps x and y)
                        // would turn it into a nonsense real coordinate, so map only real points.
                        let p = isUnspecifiedDestinationPoint(dest.point)
                            ? dest.point
                            : mappingPoint(index, dest.point)
                        kept.destination = PDFDestination(
                            page: outPage,
                            at: CGPoint(
                                x: clampedDestinationCoordinate(p.x, low: box.minX, high: box.maxX),
                                y: clampedDestinationCoordinate(p.y, low: box.minY, high: box.maxY)
                            )
                        )
                    }
                }
                if kept.destination == nil, let action = child.action, !(action is PDFActionGoTo) {
                    // A GoTo action is deliberately excluded: it points at a *source* page object,
                    // which means nothing in `output`. Everything else (URL, named, remote GoTo)
                    // is page-independent and survives the copy intact.
                    kept.action = action
                }
                parent.insertChild(kept, at: parent.numberOfChildren)
                rebuild(child, into: kept)
            }
        }

        let newRoot = PDFOutline()
        rebuild(sourceRoot, into: newRoot)
        if newRoot.numberOfChildren > 0 {
            output.outlineRoot = newRoot
        }
    }

    /// Clamps one destination coordinate into the trimmed crop box — unless it is PDFKit's
    /// "unspecified" sentinel, which must be passed through untouched.
    ///
    /// A `/FitH`-style destination ("show this page fitted", no explicit scroll position) is
    /// expressed as `kPDFDestinationUnspecifiedValue` (= FLT_MAX) in the coordinate, and it DOES
    /// survive a PDFKit write/read round trip (verified empirically). Clamping treated that
    /// sentinel as a real coordinate and pinned it to the box corner: cropping a document turned
    /// every "fit the page" bookmark into "scroll to the top-right corner" — measured as
    /// `(3.4e+38, 3.4e+38)` becoming `(582, 762)` on a 30 pt trim of US Letter. Recognizing the
    /// sentinel keeps a Fit bookmark a Fit bookmark, while a real point still gets clamped into the
    /// visible region (the reason the clamp exists).
    static func clampedDestinationCoordinate(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard value != CGFloat(kPDFDestinationUnspecifiedValue) else { return value }
        return min(max(value, low), high)
    }

    /// True when either coordinate is that same "unspecified" sentinel — i.e. a "fit the page"
    /// destination with no real scroll position, so there is nothing meaningful to transform.
    static func isUnspecifiedDestinationPoint(_ point: CGPoint) -> Bool {
        point.x == CGFloat(kPDFDestinationUnspecifiedValue) || point.y == CGFloat(kPDFDestinationUnspecifiedValue)
    }

    /// Copies the source's user-set info fields onto a page-copy rebuild. A fresh `PDFDocument`
    /// starts with an empty info dictionary, so without this a crop silently stripped the
    /// document's Title/Author — which contradicts "Strip metadata on export" defaulting to OFF.
    static func carryDocumentAttributes(from source: PDFDocument, to output: PDFDocument) {
        let attributes = restorableAttributes(of: source)
        if !attributes.isEmpty { output.documentAttributes = attributes }
    }

    /// Crops every page to its rendered content bounds plus `padding` points of breathing room.
    static func autoCrop(inputURL: URL, outputURL: URL, padding: CGFloat, unified: Bool) throws {
        try requireDistinctOutput(outputURL, from: [inputURL])
        try writeOutput(try autoCropData(inputURL: inputURL, padding: padding, unified: unified), to: outputURL)
    }

    /// In-memory core of ``autoCrop(inputURL:outputURL:padding:unified:)``.
    ///
    /// Each page is rendered small and scanned for non-background pixels; the tight box those
    /// pixels span becomes the crop (in displayed space, then mapped through rotation like
    /// ``crop(inputURL:outputURL:insets:)``). With `unified` on, the smallest per-edge trim that
    /// is safe on every page is applied uniformly, so a book scan keeps a steady frame. Pages with
    /// no detectable content (blank separators) are left uncropped in per-page mode and don't
    /// shrink the unified trim; a page whose content box would fall under the minimum side keeps
    /// its original crop rather than failing the whole run.
    public static func autoCropData(inputURL: URL, padding: CGFloat, unified: Bool) throws -> Data {
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        var perPage: [CropInsets?] = []
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            perPage.append(contentInsets(of: page, padding: padding))
        }

        let applied: [CropInsets?]
        if unified {
            let detected = perPage.compactMap { $0 }
            if let first = detected.first {
                let shared = detected.dropFirst().reduce(first, CropInsets.elementWiseMin)
                applied = Array(repeating: shared, count: perPage.count)
            } else {
                applied = perPage   // nothing detectable anywhere: change nothing
            }
        } else {
            applied = perPage
        }

        let output = PDFDocument()
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i), let copy = page.copy() as? PDFPage else {
                throw PDFOperationError.couldNotOpen(inputURL)
            }
            if let insets = applied[i], !insets.isZero {
                let cropped = insetRect(page.bounds(for: .cropBox), rotation: page.rotation, by: insets)
                if cropped.width >= minimumCropSide, cropped.height >= minimumCropSide {
                    copy.setBounds(cropped, for: .cropBox)
                }
            }
            output.insert(copy, at: output.pageCount)
        }
        reattachOutline(from: source, to: output)
        remapInternalLinksOfFullCopy(from: source, to: output)
        carryDocumentAttributes(from: source, to: output)
        guard let data = output.dataRepresentation() else {
            throw PDFOperationError.couldNotEncodeOutput
        }
        return data
    }

    /// A display-only copy of `source` for the drag-to-crop marquee's live `PDFView`: every page is
    /// copied into a *fresh* document with its annotations removed.
    ///
    /// The marquee only needs a page to draw a rectangle on — it reads geometry from the crop box and
    /// maps through `pdfView.convert`, and the actual crop re-opens the original file. Handing the raw
    /// document to a `PDFView` is what made a heavy form (e.g. a scanned government form with hundreds
    /// of fields) hang the app: PDFKit spun up a per-field `formFillingQueue` thread storm (measured at
    /// 500+ threads, ~2.6 GB) plus a Vision Live-Text pass, none of which cropping uses. Rebuilding into
    /// a fresh `PDFDocument` drops the catalog `/AcroForm`, and removing each page's widgets drops the
    /// annotations the copy would otherwise keep — so the view has nothing to form-fill. Page copies
    /// preserve bounds and `/Rotate`, so the marquee's page↔view math is unchanged.
    public static func interactivePreviewDocument(from source: PDFDocument) -> PDFDocument {
        let output = PDFDocument()
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i), let copy = page.copy() as? PDFPage else {
                // A page we can't copy would leave the preview SHORTER than the source, and the crop
                // maps the marquee's page index onto the ORIGINAL file — so a dropped page would crop
                // the wrong page. Correctness beats the strip here: fall back to the source document
                // (the form/annotation cost the strip avoids is moot on an already-degenerate file).
                return source
            }
            for annotation in copy.annotations {
                copy.removeAnnotation(annotation)
            }
            output.insert(copy, at: output.pageCount)
        }
        carryDocumentAttributes(from: source, to: output)
        return output
    }

    // MARK: Geometry

    /// Applies displayed-edge insets to a stored (unrotated) box, mapping each visual edge onto the
    /// media edge it lands on under the page's intrinsic rotation.
    ///
    /// Rotation is clockwise-on-display: at 90° the stored left edge (minX) is what the viewer sees
    /// on top, at 180° the stored bottom (minY) is on top, at 270° the stored right (maxX) is.
    /// Derived once, verified per-rotation by the crop geometry tests.
    public static func insetRect(_ rect: CGRect, rotation: Int, by insets: CropInsets) -> CGRect {
        let r = normalizedRotation(rotation)
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch r {
        case 90:
            minX += insets.top
            maxY -= insets.right
            maxX -= insets.bottom
            minY += insets.left
        case 180:
            minY += insets.top
            minX += insets.right
            maxY -= insets.bottom
            maxX -= insets.left
        case 270:
            maxX -= insets.top
            minY += insets.right
            minX += insets.bottom
            maxY -= insets.left
        default:
            maxY -= insets.top
            maxX -= insets.right
            minY += insets.bottom
            minX += insets.left
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Inverse of ``insetRect(_:rotation:by:)``: the displayed-edge insets that crop `cropBox` down
    /// to `selection`. Both rects are in the same stored (unrotated) page space — `selection` is a
    /// marquee the user dragged directly on the page, expressed via `pdfView.convert`, which never
    /// rotates. Feeding the result back through `insetRect` reproduces `selection`, so a drawn box
    /// and the numeric Top/Bottom/Left/Right fields stay two ways of saying the same thing.
    ///
    /// The four stored gaps between the boxes are relabelled onto the visual edges the same way
    /// `insetRect` maps them the other direction: at 90° the stored left gap is the trim the viewer
    /// sees on top, and so on. Clamped to ≥ 0 so a selection nudged a hair past an edge reads as a
    /// flush (zero) trim rather than a negative one.
    public static func insets(from selection: CGRect, rotation: Int, in cropBox: CGRect) -> CropInsets {
        let storedTop = max(0, cropBox.maxY - selection.maxY)
        let storedBottom = max(0, selection.minY - cropBox.minY)
        let storedLeft = max(0, selection.minX - cropBox.minX)
        let storedRight = max(0, cropBox.maxX - selection.maxX)
        switch normalizedRotation(rotation) {
        case 90:
            return CropInsets(top: storedLeft, left: storedBottom, bottom: storedRight, right: storedTop)
        case 180:
            return CropInsets(top: storedBottom, left: storedRight, bottom: storedTop, right: storedLeft)
        case 270:
            return CropInsets(top: storedRight, left: storedTop, bottom: storedLeft, right: storedBottom)
        default:
            return CropInsets(top: storedTop, left: storedLeft, bottom: storedBottom, right: storedRight)
        }
    }

    /// The displayed-edge trims that would tighten `page`'s crop box to its rendered content plus
    /// `padding`, or nil when no content is detectable (a blank page).
    ///
    /// Rendered via `thumbnail(of:for:.cropBox)`, which applies rotation and crop exactly as a
    /// viewer would — so the scan happens in displayed space and the result plugs straight into
    /// ``insetRect(_:rotation:by:)``. ~600 px on the long edge resolves a point to well under a
    /// millimeter of trim, plenty for margins.
    static func contentInsets(of page: PDFPage, padding: CGFloat) -> CropInsets? {
        // Pool per call (= per page in autoCrop's loop): the thumbnail, its TIFF, and the bitmap
        // rep are all page-sized transients; only the tiny CropInsets value leaves.
        autoreleasepool { contentInsetsBody(of: page, padding: padding) }
    }

    private static func contentInsetsBody(of page: PDFPage, padding: CGFloat) -> CropInsets? {
        let crop = page.bounds(for: .cropBox)
        let displaySize = displayedSize(of: crop, rotation: page.rotation)
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }

        let longest = max(displaySize.width, displaySize.height)
        let scale = min(1, 600 / longest)
        let thumbSize = NSSize(width: max(8, displaySize.width * scale),
                               height: max(8, displaySize.height * scale))
        let image = page.thumbnail(of: thumbSize, for: .cropBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return nil }
        var minCol = Int.max
        var maxCol = -1
        var minRow = Int.max
        var maxRow = -1

        // Anything meaningfully darker than paper counts as content ((r+g+b)/765 < 0.92); the
        // thumbnail is drawn on an opaque white ground, so alpha needs no separate handling.
        let threshold = 704   // 0.92 × 765, rounded

        if !rep.isPlanar, rep.bitsPerSample == 8, rep.samplesPerPixel >= 3, let base = rep.bitmapData {
            // Fast path: 8-bit meshed RGB(A) — the format thumbnail TIFFs actually produce. The
            // per-pixel colorAt + usingColorSpace alternative allocates two NSColors per pixel
            // (~half a million per page); raw sample reads do the same threshold test for free.
            let rowBytes = rep.bytesPerRow
            let samples = rep.samplesPerPixel
            let rgbOffset = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            for row in 0..<height {
                let rowPtr = base + row * rowBytes
                for col in 0..<width {
                    let p = rowPtr + col * samples + rgbOffset
                    if Int(p[0]) + Int(p[1]) + Int(p[2]) < threshold {
                        if col < minCol { minCol = col }
                        if col > maxCol { maxCol = col }
                        if row < minRow { minRow = row }
                        if row > maxRow { maxRow = row }
                    }
                }
            }
        } else {
            // Exotic formats (planar, deep color, narrow gray) fall back to the slow universal
            // accessor rather than misreading bytes.
            for row in 0..<height {
                for col in 0..<width {
                    guard let color = rep.colorAt(x: col, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                    let sum = Int((color.redComponent + color.greenComponent + color.blueComponent) * 255)
                    if sum < threshold {
                        minCol = min(minCol, col)
                        maxCol = max(maxCol, col)
                        minRow = min(minRow, row)
                        maxRow = max(maxRow, row)
                    }
                }
            }
        }
        guard maxCol >= 0 else { return nil }

        // Bitmap rows count down from the displayed top; undo the render scale, then pad.
        let sx = displaySize.width / CGFloat(width)
        let sy = displaySize.height / CGFloat(height)
        return CropInsets(
            top: max(0, CGFloat(minRow) * sy - padding),
            left: max(0, CGFloat(minCol) * sx - padding),
            bottom: max(0, (displaySize.height - CGFloat(maxRow + 1) * sy) - padding),
            right: max(0, (displaySize.width - CGFloat(maxCol + 1) * sx) - padding)
        )
    }
}
