import Testing
import CoreGraphics
@testable import PDFToolkitCore

/// The pure geometry behind placing fill-and-sign items: mapping a signature's normalized (y-down)
/// points into a page rect (y-up) and back, keeping a dragged item inside the page, and building a
/// rect from a resize handle. No PDFKit or AppKit — just the math the canvas and exporter must agree on.
@Suite struct FillSignGeometryTests {

    // MARK: normalized <-> page point

    @Test func normalizedCornersMapToTheExpectedPageCorners() {
        let rect = CGRect(x: 100, y: 200, width: 80, height: 40)
        // (0,0) is top-left in normalized (y-down) space → the page's top-left is (minX, maxY) in y-up.
        #expect(FillSignGeometry.pagePoint(normalized: CGPoint(x: 0, y: 0), in: rect) == CGPoint(x: 100, y: 240))
        // (1,1) is bottom-right → (maxX, minY).
        #expect(FillSignGeometry.pagePoint(normalized: CGPoint(x: 1, y: 1), in: rect) == CGPoint(x: 180, y: 200))
        // Center maps to center.
        #expect(FillSignGeometry.pagePoint(normalized: CGPoint(x: 0.5, y: 0.5), in: rect) == CGPoint(x: 140, y: 220))
    }

    @Test func pageAndNormalizedPointsRoundTrip() {
        // A signature captured on the canvas (normalized), placed into a rect, must map back to the
        // same normalized point — otherwise the preview and the baked ink would drift apart.
        let rect = CGRect(x: 12, y: 34, width: 200, height: 90)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.9), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
            let page = FillSignGeometry.pagePoint(normalized: p, in: rect)
            let back = FillSignGeometry.normalizedPoint(page: page, in: rect)
            #expect(abs(back.x - p.x) < 1e-9)
            #expect(abs(back.y - p.y) < 1e-9)
        }
    }

    @Test func normalizedPointOfADegenerateRectIsZero() {
        let rect = CGRect(x: 5, y: 5, width: 0, height: 0)
        #expect(FillSignGeometry.normalizedPoint(page: CGPoint(x: 5, y: 5), in: rect) == .zero)
    }

    // MARK: isMeaningful

    @Test func meaningfulRequiresBothSidesAtLeastTheMinimum() {
        let min = FillSignGeometry.minimumSidePt
        #expect(FillSignGeometry.isMeaningful(CGRect(x: 0, y: 0, width: min, height: min)))
        #expect(!FillSignGeometry.isMeaningful(CGRect(x: 0, y: 0, width: min - 0.1, height: 100)))
        #expect(!FillSignGeometry.isMeaningful(CGRect(x: 0, y: 0, width: 100, height: min - 0.1)))
    }

    // MARK: clamped

    private let page = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func clampLeavesAContainedRectUntouched() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(FillSignGeometry.clamped(rect, in: page) == rect)
    }

    @Test func clampPullsAnOverhangingRectBackInsideKeepingItsSize() {
        // Dragged off the top-right: origin is nudged so the whole 20×20 box sits inside the page.
        let rect = CGRect(x: 90, y: 95, width: 20, height: 20)
        #expect(FillSignGeometry.clamped(rect, in: page) == CGRect(x: 80, y: 80, width: 20, height: 20))
    }

    @Test func clampShrinksARectLargerThanThePage() {
        let rect = CGRect(x: -10, y: -10, width: 200, height: 50)
        let clamped = FillSignGeometry.clamped(rect, in: page)
        #expect(clamped == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    // MARK: resizedRect

    @Test func resizeBuildsARectBetweenAnchorAndCornerRegardlessOfDirection() {
        // Anchor at the visual top-left (y-up: maxY), corner dragged to the bottom-right.
        let r = FillSignGeometry.resizedRect(anchor: CGPoint(x: 20, y: 60), corner: CGPoint(x: 70, y: 10))
        #expect(r == CGRect(x: 20, y: 10, width: 50, height: 50))
    }

    @Test func resizeEnforcesAMinimumSide() {
        let min = FillSignGeometry.minimumSidePt
        // Corner dragged almost onto the anchor: each side is floored at the minimum.
        let r = FillSignGeometry.resizedRect(anchor: CGPoint(x: 20, y: 60), corner: CGPoint(x: 21, y: 59))
        #expect(r.width == min)
        #expect(r.height == min)
    }

    // MARK: placedRect (new-item placement)

    private let letterPage = CGRect(x: 0, y: 0, width: 612, height: 792)

    @Test func firstPlacementCentersOnTheGivenPoint() {
        // Cascade 0: the size is centered exactly on the target point (the visible center of the page).
        let rect = FillSignGeometry.placedRect(center: CGPoint(x: 300, y: 400), size: CGSize(width: 100, height: 40), cascade: 0, in: letterPage)
        #expect(rect == CGRect(x: 250, y: 380, width: 100, height: 40))
    }

    @Test func cascadeStepsDownAndRightSoAddsDoNotStack() {
        let size = CGSize(width: 100, height: 40)
        let center = CGPoint(x: 300, y: 400)
        let first = FillSignGeometry.placedRect(center: center, size: size, cascade: 0, in: letterPage)
        let second = FillSignGeometry.placedRect(center: center, size: size, cascade: 1, in: letterPage)
        #expect(second.minX > first.minX)   // to the right
        #expect(second.minY < first.minY)   // visually downward (page space is y-up)
        #expect(second != first)
    }

    @Test func cascadeWrapsSoItNeverMarchesOffThePage() {
        // The step wraps at `wrap`, so cascade 0 and cascade `wrap` land identically.
        let size = CGSize(width: 100, height: 40)
        let center = CGPoint(x: 300, y: 400)
        let base = FillSignGeometry.placedRect(center: center, size: size, cascade: 0, in: letterPage, step: 22, wrap: 5)
        let wrapped = FillSignGeometry.placedRect(center: center, size: size, cascade: 5, in: letterPage, step: 22, wrap: 5)
        #expect(base == wrapped)
    }

    @Test func placementStaysInsideThePageEvenNearAnEdge() {
        // Centered at the bottom-right corner: the box is clamped fully inside the page.
        let rect = FillSignGeometry.placedRect(center: CGPoint(x: 610, y: 5), size: CGSize(width: 120, height: 40), cascade: 3, in: letterPage)
        #expect(rect.minX >= letterPage.minX)
        #expect(rect.minY >= letterPage.minY)
        #expect(rect.maxX <= letterPage.maxX)
        #expect(rect.maxY <= letterPage.maxY)
    }
}
