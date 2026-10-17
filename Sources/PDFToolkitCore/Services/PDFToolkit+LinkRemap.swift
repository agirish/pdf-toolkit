import CoreGraphics
import Foundation
import PDFKit

/// Re-pointing the internal links on pages copied into a fresh document.
///
/// The page-copy rebuilds (Extract, Reorder, Crop, Auto-crop, Clean Metadata, Remove Password, the
/// untouched pages of Redact, and the copy ``restoringCatalog(_:from:restoreLinks:displayMappedPages:)``
/// makes of every rebuild's pages) keep each page's link annotations, but not where an internal link
/// goes. That depends on the source document, and PDFKit does not carry it across reliably. Measured
/// on macOS 27.0.1 against a Chrome-printed book whose ten internal links are all *named*
/// destinations (`/Dest /two`, resolved through the catalog `/Dests` dictionary):
///
/// - Extract, Reorder, Crop and Redact wrote `/Dest /two` with no `/Dests` to resolve it against —
///   every link dead.
/// - Auto-crop wrote an explicit destination, but chose the page by its *source* index — 8 of 10
///   links landed on the wrong page.
/// - An explicit-array link (`/Dest [page /XYZ …]`) fared no better: after a reorder it, too,
///   pointed at whichever output page now sits at the source page's old index.
///
/// Which of those PDFKit does varies by operation, for reasons the API does not show (Clean
/// Metadata happened to come through intact), so no operation can be trusted to get it right by
/// accident. Instead every
/// internal link is resolved on the SOURCE, where the catalog still exists, and rewritten as an
/// explicit GoTo onto the output page its target was copied to — the rule ``remapOutline`` applies
/// to bookmarks.
extension PDFToolkit {
    /// Rewrites every internal link on the copied pages of `output` to point at the output page its
    /// source target now occupies; a link whose target page was not kept is removed rather than left
    /// as a hotspot that goes nowhere (or somewhere wrong).
    ///
    /// - Parameter copiedPages: each output page that is a `PDFPage.copy()` of a source page, as
    ///   `(output index, source index)`. Pages built any other way (Redact's rasterized pages) carry
    ///   no source annotations and are left out.
    /// - Parameter sourceToOutput: the output index each source page now occupies — the map that
    ///   decides where a link lands, and whether it survives at all. First occurrence wins when a
    ///   page was copied more than once.
    /// - Parameter mappingPoint: converts a destination point on the given *source* page index into
    ///   the space of the output page it maps to. Identity for a whole-page copy, which keeps the
    ///   source's boxes and `/Rotate`. Redact passes a display-space mapping for the pages it
    ///   rasterized upright.
    ///
    /// Links are paired with their source by position in the page's annotation list. A copy keeps
    /// that list in order, but if the two lists disagree in length or type (a copy whose annotations
    /// were stripped), the page is left exactly as PDFKit wrote it rather than re-pointed on a guess.
    /// URL links, remote GoTos and named actions are page-independent and never touched.
    static func remapInternalLinks(
        from source: PDFDocument,
        to output: PDFDocument,
        copiedPages: [(output: Int, source: Int)],
        sourceToOutput: [Int: Int],
        mappingPoint: (Int, CGPoint) -> CGPoint = { _, point in point }
    ) {
        for (outIndex, srcIndex) in copiedPages {
            guard let sourcePage = source.page(at: srcIndex), let outPage = output.page(at: outIndex) else { continue }
            let sourceAnnotations = sourcePage.annotations
            let outAnnotations = outPage.annotations
            guard sourceAnnotations.count == outAnnotations.count,
                  zip(sourceAnnotations, outAnnotations).allSatisfy({ $0.type == $1.type })
            else { continue }

            for (original, copy) in zip(sourceAnnotations, outAnnotations) where original.type == "Link" {
                // An internal jump can arrive either as a destination or as a GoTo action. A named
                // destination is resolved here, through the source's catalog.
                guard original.url == nil,
                      let target = original.destination ?? (original.action as? PDFActionGoTo)?.destination
                else { continue }
                // Dead in the source too: there is nothing to carry, so leave it as it was.
                guard let targetPage = target.page else { continue }
                let targetIndex = source.index(for: targetPage)
                guard targetIndex != NSNotFound else { continue }

                guard let mappedIndex = sourceToOutput[targetIndex], let mappedPage = output.page(at: mappedIndex) else {
                    outPage.removeAnnotation(copy)
                    continue
                }
                // Clamped into the target's crop box, with the "fit the page" sentinel passed
                // through, for the reasons ``reattachOutline(from:to:mappingPoint:)`` gives: a crop
                // can leave a stored point outside the visible page.
                let box = mappedPage.bounds(for: .cropBox)
                let point = isUnspecifiedDestinationPoint(target.point)
                    ? target.point
                    : mappingPoint(targetIndex, target.point)
                let destination = PDFDestination(
                    page: mappedPage,
                    at: CGPoint(
                        x: clampedDestinationCoordinate(point.x, low: box.minX, high: box.maxX),
                        y: clampedDestinationCoordinate(point.y, low: box.minY, high: box.maxY)
                    )
                )
                // One entry, not two: clearing `/Dest` keeps a stale name from competing with the
                // GoTo in readers that prefer it.
                copy.destination = nil
                copy.action = PDFActionGoTo(destination: destination)
            }
        }
    }

    /// ``remapInternalLinks(from:to:copiedPages:sourceToOutput:mappingPoint:)`` for a rebuild that
    /// copied every page, in order (Crop, Auto-crop, Clean Metadata, Remove Password).
    static func remapInternalLinksOfFullCopy(from source: PDFDocument, to output: PDFDocument) {
        let indices = 0..<min(source.pageCount, output.pageCount)
        remapInternalLinks(
            from: source,
            to: output,
            copiedPages: indices.map { ($0, $0) },
            sourceToOutput: Dictionary(uniqueKeysWithValues: indices.map { ($0, $0) })
        )
    }
}
