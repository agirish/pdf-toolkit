import CoreGraphics
import Foundation
import PDFKit

/// Carrying a rebuilt document's *catalog* across — bookmarks, the info dictionary, and link
/// annotations.
///
/// The page-for-page rebuild operations (Watermark, OCR, Fill & Sign, Compress, Redact) emit their
/// result through a `CGPDFContext`, which knows only about pages. Everything that lives on the PDF
/// *catalog* rather than on a page therefore vanished: a 3-bookmark source came back with 0, the
/// document Title/Author were gone, and every hyperlink was dead (verified empirically across all
/// five). That is silent data loss on the user's document — a 400-page OCR'd book lost its whole
/// navigation — and it contradicted the care the subset/reorder paths already take
/// (``PDFToolkit/remapOutline``, ``PDFToolkit/reattachOutline(from:to:)``).
///
/// These rebuilds all emit **every** page, **in order**, so the source catalog maps 1:1 onto the
/// result and can simply be reattached.
extension PDFToolkit {
    /// Returns `data` — the bytes of a page-for-page rebuild of `source` — with the source's
    /// bookmarks, info dictionary, and (optionally) link annotations restored.
    ///
    /// Fail-safe in every direction: nothing to restore, unreadable output, a page-count mismatch,
    /// or an encode failure all return `data` untouched. A rebuild that lost its catalog is bad; a
    /// rebuild that loses the whole export is worse.
    ///
    /// - Parameter restoreLinks: whether to re-create the source's link annotations on the rebuilt
    ///   pages. False for Redact, where a link's URL can itself disclose the value the user just
    ///   painted over — and where a live annotation sitting on top of a burned-in black box is
    ///   exactly the "recoverable content" the tool promises to destroy.
    /// - Parameter displayMappedPages: which output pages were emitted in *display space* (upright,
    ///   zero origin) rather than copied whole. `nil` — the default — means every page, which is
    ///   true of the four uniform rebuilds. **Redact is the exception**: it rasterizes only the
    ///   pages carrying marks and copies the rest untouched, so its output is mixed-space and a
    ///   single blanket mapping is wrong for half of it (measured: a bookmark into an unmarked
    ///   page with crop origin (50, 60) and `/Rotate 90` moved from (100, 400) to (340, 350) —
    ///   the right answer for a rasterized page, the wrong one for a copied page).
    static func restoringCatalog(
        _ data: Data,
        from source: PDFDocument,
        restoreLinks: Bool,
        displayMappedPages: Set<Int>? = nil
    ) -> Data {
        let attributes = restorableAttributes(of: source)
        let links = restoreLinks ? sourceLinks(of: source) : [:]
        // Nothing worth carrying: skip the reopen-and-re-serialize entirely. This is the common case
        // for the scans Compress exists for, and it matters — `compressToTargetData` sweeps a quality
        // ladder, so a restore pass here would be paid once per rung.
        guard source.outlineRoot != nil || !attributes.isEmpty || !links.isEmpty else { return data }

        guard let rebuilt = PDFDocument(data: data),
              rebuilt.pageCount == source.pageCount
        else { return data }

        // Destination points, like the link bounds in `sourceLinks`, are stored in the source's
        // unrotated user space while the rebuilt pages are emitted upright at a zero origin. A
        // bookmark into a rotated (or non-zero-origin) page therefore has to go through the same
        // display mapping the page content did, or it scrolls the reader to the wrong place.
        reattachOutline(from: source, to: rebuilt) { pageIndex, point in
            // A page that was copied whole keeps the source's box and `/Rotate`, so its destinations
            // are already in the right space — mapping them would move the bookmark off its anchor.
            guard displayMappedPages?.contains(pageIndex) ?? true else { return point }
            guard let page = source.page(at: pageIndex) else { return point }
            return displayPoint(point, cropBox: page.bounds(for: .cropBox), rotation: normalizedRotation(page.rotation))
        }
        if !attributes.isEmpty {
            rebuilt.documentAttributes = attributes
        }
        for (pageIndex, annotations) in links {
            guard let page = rebuilt.page(at: pageIndex) else { continue }
            for link in annotations {
                page.addAnnotation(link.rebuilt(in: rebuilt))
            }
        }

        guard let restored = rebuilt.dataRepresentation() else { return data }
        return restored
    }

    /// The info-dictionary fields worth carrying onto a rebuild: the ones a *user* set.
    ///
    /// Deliberately not the whole dictionary. PDFKit re-stamps Producer and both dates with its own
    /// values on every write regardless of what is set here (see ``PDFMetadataFields``), so carrying
    /// them buys nothing — while making the "is there anything to restore?" test above true for
    /// nearly every file, since almost every producer writes at least a Producer string. Restricting
    /// it to the five editable fields keeps the fast path fast and still honors what "Strip metadata
    /// on export" (default OFF) promises: a tool run does not quietly erase your document's title.
    // Internal (not private): the page-copy rebuilds in sibling files (extract/reorder, crop) apply
    // the same carry-over. They build a fresh `PDFDocument` rather than a `CGPDFContext`, so they
    // set these directly instead of going through ``restoringCatalog(_:from:restoreLinks:)``.
    static func restorableAttributes(of source: PDFDocument) -> [AnyHashable: Any] {
        let keys: [PDFDocumentAttribute] = [
            .titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute,
        ]
        let all = source.documentAttributes ?? [:]
        var kept: [AnyHashable: Any] = [:]
        for key in keys {
            guard let value = all[key] else { continue }
            // An empty string or empty keyword list is "no value" — writing it back would turn an
            // absent field into a present-but-blank one.
            if let text = value as? String, text.isEmpty { continue }
            if let list = value as? [String], list.isEmpty { continue }
            kept[key] = value
        }
        return kept
    }

    /// One source link, captured as plain values in the *display space* the rebuilt page uses.
    ///
    /// The rebuilds emit each page with its crop box mapped to a zero-origin, rotation-upright box,
    /// so a link's stored user-space rect has to go through the same mapping the content did — the
    /// one ``PDFToolkit/displayRect(_:cropBox:rotation:)`` already performs for Fill & Sign items.
    private struct SourceLink {
        let bounds: CGRect
        let url: URL?
        /// For an internal (GoTo) link: the destination's page index and point in the source.
        let destination: (pageIndex: Int, point: CGPoint)?

        /// A fresh annotation on `document`, resolving an internal destination onto the rebuilt page.
        func rebuilt(in document: PDFDocument) -> PDFAnnotation {
            let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
            if let url {
                annotation.url = url
            } else if let destination, let target = document.page(at: destination.pageIndex) {
                annotation.action = PDFActionGoTo(
                    destination: PDFDestination(page: target, at: destination.point)
                )
            }
            return annotation
        }
    }

    /// The source's link annotations per page index, already mapped into display space. Links with
    /// neither a URL nor a resolvable destination are dropped — re-creating a link that goes nowhere
    /// would just leave a dead hotspot on the page.
    private static func sourceLinks(of source: PDFDocument) -> [Int: [SourceLink]] {
        var result: [Int: [SourceLink]] = [:]
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else { continue }
            let cropBox = page.bounds(for: .cropBox)
            let rotation = normalizedRotation(page.rotation)
            let links: [SourceLink] = page.annotations.compactMap { annotation in
                guard annotation.type == "Link" else { return nil }
                let bounds = displayRect(annotation.bounds, cropBox: cropBox, rotation: rotation)
                guard bounds.width > 0, bounds.height > 0 else { return nil }
                if let url = annotation.url {
                    return SourceLink(bounds: bounds, url: url, destination: nil)
                }
                // An internal jump can arrive either as a destination or as a GoTo action.
                let target = annotation.destination
                    ?? (annotation.action as? PDFActionGoTo)?.destination
                guard let target, let targetPage = target.page else { return nil }
                let targetIndex = source.index(for: targetPage)
                guard targetIndex != NSNotFound else { return nil }
                // The destination point needs the same display mapping as the bounds above — but
                // against the *target* page's box and rotation, not this link's page. A "Fit"-style
                // destination carries the unspecified sentinel instead of a real coordinate, and the
                // mapping swaps/negates coordinates on a rotated page — which turned `+FLT_MAX` into
                // `-FLT_MAX`, a sentinel PDFKit no longer recognizes, so "fit the page" became a
                // jump far off the page. Pass the sentinel through, exactly as `reattachOutline`
                // does for bookmarks.
                let targetPoint = isUnspecifiedDestinationPoint(target.point)
                    ? target.point
                    : displayPoint(
                        target.point,
                        cropBox: targetPage.bounds(for: .cropBox),
                        rotation: normalizedRotation(targetPage.rotation)
                    )
                return SourceLink(
                    bounds: bounds,
                    url: nil,
                    destination: (targetIndex, targetPoint)
                )
            }
            if !links.isEmpty { result[index] = links }
        }
        return result
    }
}
