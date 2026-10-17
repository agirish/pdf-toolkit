import CoreGraphics
import Foundation

/// Where a redaction mark came from — a hand-drawn ⇧-drag or an auto-detected Find & redact match.
/// Only affects presentation (auto-marks draw a dashed outline and can be cleared as a group); both
/// kinds redact identically and are edited/removed the same way.
public enum RedactionMarkOrigin: Hashable, Sendable {
    case manual
    /// Placed by a Find & redact search over the document text.
    case autoMatch
}

/// One rectangular redaction region in a document page’s PDF user space (the space `PDFView`'s
/// view→page conversion produces). The editor clips captured marks to the page's crop box — the
/// visible region — and the export clips against the same box before filling.
public struct RedactionMark: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Zero-based page index.
    public var pageIndex: Int
    /// Rectangle in PDF user space, clipped to the page's crop box at capture.
    public var rect: CGRect
    /// How the mark was created. Defaults to `.manual` so hand-drawn marks and every existing call
    /// site are unaffected; Find & redact stamps `.autoMatch`.
    public var origin: RedactionMarkOrigin

    public init(id: UUID = UUID(), pageIndex: Int, rect: CGRect, origin: RedactionMarkOrigin = .manual) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
        self.origin = origin
    }
}

public enum RedactionMarkGeometry {
    static let minimumSidePt: CGFloat = 4

    public static func normalizedDragRect(start: CGPoint, end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public static func isMeaningful(_ rect: CGRect) -> Bool {
        rect.width >= minimumSidePt && rect.height >= minimumSidePt
    }

    /// Clips `rect` to `box`, returning the intersection — or `nil` if the surviving overlap is a
    /// sliver thinner than `minimumSidePt / 2` on either axis (so a mark that only grazes the box is
    /// dropped rather than kept as a hairline). Every caller passes the page's *crop* box — the
    /// region the user can see and the same box the export fills against — not the media box.
    public static func clip(_ rect: CGRect, to box: CGRect) -> CGRect? {
        let i = rect.intersection(box)
        guard i.width >= minimumSidePt / 2, i.height >= minimumSidePt / 2 else { return nil }
        return i
    }

    /// Keeps a mark fully inside the page while it is dragged to a new position: shrinks it if it is
    /// larger than the page, then slides it back in from whichever edge it overhangs. Mirrors the
    /// clamp Fill & Sign uses so a mark can't be dragged off-page.
    public static func clamped(_ rect: CGRect, in pageBox: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, pageBox.width)
        r.size.height = min(r.height, pageBox.height)
        if r.minX < pageBox.minX { r.origin.x = pageBox.minX }
        if r.minY < pageBox.minY { r.origin.y = pageBox.minY }
        if r.maxX > pageBox.maxX { r.origin.x = pageBox.maxX - r.width }
        if r.maxY > pageBox.maxY { r.origin.y = pageBox.maxY - r.height }
        return r
    }

    /// Builds a rect from a fixed anchor corner (the one diagonally opposite the grabbed handle) and
    /// the dragged corner, flooring each side at ``minimumSidePt`` so a resize can never collapse the
    /// mark to nothing. The corner handle passes the anchor it captured at drag start.
    public static func resizedRect(anchor: CGPoint, corner: CGPoint) -> CGRect {
        let minX = min(anchor.x, corner.x)
        let minY = min(anchor.y, corner.y)
        let width = max(minimumSidePt, abs(corner.x - anchor.x))
        let height = max(minimumSidePt, abs(corner.y - anchor.y))
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}
