import CoreGraphics
import Foundation

/// The face a ``FillSignText`` is drawn in, when it is not the default one.
public enum FillSignFont: Hashable, Sendable {
    /// A font by its PostScript name — "SavoyeLetPlain", "Charter-Roman". A name this Mac doesn't
    /// have falls back to the default face for the run (``FillSignText/isScript``).
    case named(String)
    /// The system font's rounded design.
    case systemRounded
    /// The system font's monospaced design.
    case systemMonospaced
}

/// A typed-text run placed on a page. Baked as **selectable vector text** (CoreText), not a bitmap.
public struct FillSignText: Hashable, Sendable {
    public var string: String
    /// Point size in PDF user space (page points).
    public var fontSize: CGFloat
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    /// When true, the run is drawn in a handwriting/script face — a "typed signature".
    public var isScript: Bool
    /// The face to draw in, tried first; `nil`, or a face this Mac lacks, is the default one —
    /// the script chain for a typed signature, the system font for anything else.
    public var font: FillSignFont?

    public init(
        string: String,
        fontSize: CGFloat,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        isScript: Bool = false,
        font: FillSignFont? = nil
    ) {
        self.string = string
        self.fontSize = fontSize
        self.red = red
        self.green = green
        self.blue = blue
        self.isScript = isScript
        self.font = font
    }

    public var hasInk: Bool {
        !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A freehand signature captured on the drawing canvas. Strokes are stored **normalized** to the
/// item's rectangle (0…1, y **down** / top-left origin) so the same path scales to any placement
/// size; the export bakes them as a stroked vector path — no image round-trip, no transparency loss.
public struct FillSignSignature: Hashable, Sendable {
    /// Polylines. Each inner array is one continuous pen stroke; points are 0…1 within the item rect.
    public var strokes: [[CGPoint]]
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    /// Pen width as a fraction of the item rect's shorter side, so thickness tracks the placed size.
    public var penWidthFraction: CGFloat

    public static let defaultPenWidthFraction: CGFloat = 0.02

    /// The memberwise initializer, spelled out so it can be public.
    public init(strokes: [[CGPoint]], red: CGFloat, green: CGFloat, blue: CGFloat, penWidthFraction: CGFloat) {
        self.strokes = strokes
        self.red = red
        self.green = green
        self.blue = blue
        self.penWidthFraction = penWidthFraction
    }

    var hasInk: Bool {
        strokes.contains { !$0.isEmpty }
    }
}

/// One thing the user dropped onto a page: either typed text or a drawn signature, positioned by a
/// rectangle in that page's crop-box space (PDF user space, y-up) — the same coordinate convention
/// as ``RedactionMark`` so the placement canvas and the exporter agree.
public struct FillSignItem: Identifiable, Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case text(FillSignText)
        case signature(FillSignSignature)
    }

    public let id: UUID
    /// Zero-based page index.
    public var pageIndex: Int
    /// Rectangle in `PDFPage` crop-box space (PDF user space).
    public var rect: CGRect
    public var content: Content

    public init(id: UUID = UUID(), pageIndex: Int, rect: CGRect, content: Content) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
        self.content = content
    }

    public var isText: Bool {
        if case .text = content { return true }
        return false
    }

    /// Whether this item would actually draw anything (non-blank text / at least one stroke).
    public var hasInk: Bool {
        switch content {
        case .text(let t): return t.hasInk
        case .signature(let s): return s.hasInk
        }
    }
}

/// Pure geometry for placing and sizing fill-and-sign items — kept free of PDFKit/AppKit so it is
/// unit-testable. All page rectangles are in PDF user space (y-up); normalized points are y-down.
public enum FillSignGeometry {
    /// A placed box must clear this on each side, so a stray click can't leave an invisible item.
    public static let minimumSidePt: CGFloat = 8

    static func isMeaningful(_ rect: CGRect) -> Bool {
        rect.width >= minimumSidePt && rect.height >= minimumSidePt
    }

    /// Maps a normalized point (0…1, **y-down**, top-left origin) inside `rect` to a PDF user-space
    /// point (**y-up**) within that rect. Inverse of ``normalizedPoint(page:in:)``.
    public static func pagePoint(normalized p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + p.x * rect.width,
            y: rect.maxY - p.y * rect.height
        )
    }

    /// Maps a PDF user-space point (**y-up**) within `rect` back to a normalized point (0…1,
    /// **y-down**). Inverse of ``pagePoint(normalized:in:)``.
    static func normalizedPoint(page p: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: (p.x - rect.minX) / rect.width,
            y: (rect.maxY - p.y) / rect.height
        )
    }

    /// Keeps a placed rect fully inside the page: shrinks it if larger than the page, then nudges it
    /// back in from whichever edge it overhangs. Used while dragging so items can't wander off-page.
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

    /// Where a newly-placed item of `size` lands: centered on `center`, then stepped by `cascade`
    /// (0, 1, 2, …) along a fixed diagonal so successive adds fan out instead of stacking, then
    /// clamped inside `pageBox`. The step is visually down-and-right; page space is y-up, so the y
    /// term is subtracted. Pure so the placement behavior is unit-testable without a live PDFView.
    public static func placedRect(center: CGPoint, size: CGSize, cascade: Int, in pageBox: CGRect, step: CGFloat = 22, wrap: Int = 5) -> CGRect {
        let n = CGFloat(((cascade % wrap) + wrap) % wrap)
        let origin = CGPoint(
            x: center.x - size.width / 2 + n * step,
            y: center.y - size.height / 2 - n * step
        )
        return clamped(CGRect(origin: origin, size: size), in: pageBox)
    }

    /// Builds a rect from a fixed anchor corner and the dragged opposite corner, enforcing a floor on
    /// each side so a resize can't collapse the box. Used by the corner resize handle.
    public static func resizedRect(anchor: CGPoint, corner: CGPoint, minimumSide: CGFloat = minimumSidePt) -> CGRect {
        let minX = min(anchor.x, corner.x)
        let minY = min(anchor.y, corner.y)
        let width = max(minimumSide, abs(corner.x - anchor.x))
        let height = max(minimumSide, abs(corner.y - anchor.y))
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}
