import Testing
import CoreGraphics
@testable import PDFToolkitCore

/// The pure geometry behind drawing and validating redaction rectangles: normalizing a drag into a
/// positive-sized rect, rejecting rectangles too small to be a deliberate mark, and clipping a mark
/// to the page's crop box (dropping ones that barely graze it).
@Suite struct RedactionMarkGeometryTests {

    // MARK: normalizedDragRect

    @Test func normalizesADragRegardlessOfDirection() {
        // Dragging up-left must yield the same rect as dragging down-right: origin at the min corner,
        // positive width/height.
        let downRight = RedactionMarkGeometry.normalizedDragRect(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 20))
        let upLeft = RedactionMarkGeometry.normalizedDragRect(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 0, y: 0))
        #expect(downRight == CGRect(x: 0, y: 0, width: 10, height: 20))
        #expect(upLeft == downRight)
    }

    @Test func aZeroLengthDragIsAnEmptyRect() {
        let point = RedactionMarkGeometry.normalizedDragRect(start: CGPoint(x: 5, y: 5), end: CGPoint(x: 5, y: 5))
        #expect(point == CGRect(x: 5, y: 5, width: 0, height: 0))
    }

    // MARK: isMeaningful

    @Test func rectAtOrAboveTheMinimumSideIsMeaningful() {
        let min = RedactionMarkGeometry.minimumSidePt
        #expect(RedactionMarkGeometry.isMeaningful(CGRect(x: 0, y: 0, width: min, height: min)))
        #expect(RedactionMarkGeometry.isMeaningful(CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    @Test func rectSmallOnEitherAxisIsNotMeaningful() {
        // Both sides must clear the floor — a tall sliver or a wide sliver is rejected, so a stray
        // click-drag of a few points doesn't create an invisible mark.
        let min = RedactionMarkGeometry.minimumSidePt
        #expect(!RedactionMarkGeometry.isMeaningful(CGRect(x: 0, y: 0, width: min - 0.1, height: 100)))
        #expect(!RedactionMarkGeometry.isMeaningful(CGRect(x: 0, y: 0, width: 100, height: min - 0.1)))
        #expect(!RedactionMarkGeometry.isMeaningful(.zero))
    }

    // MARK: clip (intersect with the crop box, drop slivers)

    private let box = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func clipReturnsAFullyContainedRectUnchanged() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(RedactionMarkGeometry.clip(rect, to: box) == rect)
    }

    @Test func clipTrimsARectThatOverhangsTheEdge() {
        // A mark dragged past the page edge is clipped to the visible intersection.
        let rect = CGRect(x: 90, y: 90, width: 40, height: 40)
        #expect(RedactionMarkGeometry.clip(rect, to: box) == CGRect(x: 90, y: 90, width: 10, height: 10))
    }

    @Test func clipDropsARectEntirelyOutsideThePage() {
        let rect = CGRect(x: 200, y: 200, width: 10, height: 10)
        #expect(RedactionMarkGeometry.clip(rect, to: box) == nil)
    }

    @Test func clipDropsASliverThinnerThanHalfTheMinimumSide() {
        // The retained intersection must be at least minimumSidePt/2 on each axis, so a mark that
        // barely grazes the page (a 1pt overlap) is discarded rather than kept as a hairline.
        let half = RedactionMarkGeometry.minimumSidePt / 2
        // Intersection width = 1pt (< half=2) → dropped.
        let grazing = CGRect(x: 99, y: 10, width: 20, height: 20)
        #expect(RedactionMarkGeometry.clip(grazing, to: box) == nil)
        // Intersection width = exactly half → kept.
        let onBoundary = CGRect(x: 100 - half, y: 10, width: 20, height: 20)
        let clipped = RedactionMarkGeometry.clip(onBoundary, to: box)
        #expect(clipped == CGRect(x: 100 - half, y: 10, width: half, height: 20))
    }

    // MARK: clamped (move a mark, keep it on the page)

    @Test func clampLeavesAContainedMarkWhereItIs() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(RedactionMarkGeometry.clamped(rect, in: box) == rect)
    }

    @Test func clampSlidesAnOverhangingMarkBackInsideWithoutResizing() {
        // Dragged partly past the right/top edge: pushed back so it sits flush, same size.
        let rect = CGRect(x: 95, y: 92, width: 20, height: 20)
        #expect(RedactionMarkGeometry.clamped(rect, in: box) == CGRect(x: 80, y: 80, width: 20, height: 20))
    }

    @Test func clampShrinksAMarkLargerThanThePageThenPinsIt() {
        let rect = CGRect(x: -10, y: -10, width: 200, height: 50)
        let out = RedactionMarkGeometry.clamped(rect, in: box)
        #expect(out == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    // MARK: resizedRect (corner drag)

    @Test func resizeBuildsAPositiveRectFromAnchorAndCorner() {
        // Anchor bottom-left, corner dragged up-right → a normal rect between them.
        let r = RedactionMarkGeometry.resizedRect(anchor: CGPoint(x: 10, y: 10), corner: CGPoint(x: 40, y: 60))
        #expect(r == CGRect(x: 10, y: 10, width: 30, height: 50))
    }

    @Test func resizeNormalizesWhenTheCornerCrossesTheAnchor() {
        // Dragging the corner below-left of the anchor still yields a positive-sized rect.
        let r = RedactionMarkGeometry.resizedRect(anchor: CGPoint(x: 40, y: 60), corner: CGPoint(x: 10, y: 10))
        #expect(r == CGRect(x: 10, y: 10, width: 30, height: 50))
    }

    @Test func resizeFloorsEachSideAtTheMinimum() {
        // Collapsing the corner onto the anchor can't produce a zero (or sub-minimum) mark.
        let min = RedactionMarkGeometry.minimumSidePt
        let r = RedactionMarkGeometry.resizedRect(anchor: CGPoint(x: 20, y: 20), corner: CGPoint(x: 20, y: 20))
        #expect(r.width == min)
        #expect(r.height == min)
    }
}
