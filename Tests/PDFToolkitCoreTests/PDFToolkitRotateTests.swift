import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Rotate turns selected pages by `quarterTurns × 90°` clockwise, adding to any rotation already
/// baked into the page and normalizing the result into 0/90/180/270. Tests pin the modular
/// arithmetic (negative turns, turns ≥ 4, wrap past 360), the selection filter, and the
/// zero-turn passthrough.
@Suite struct PDFToolkitRotateTests {

    @Test func rotatesEverySelectedPageByOneQuarterTurn() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0, 1], quarterTurns: 1)

        #expect(try PDFFixtures.pageRotations(at: out) == [90, 90])
    }

    @Test func onlySelectedPagesRotate() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)

        try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0], quarterTurns: 1)

        #expect(try PDFFixtures.pageRotations(at: out) == [90, 0, 0])
    }

    @Test func negativeQuarterTurnsNormalizeToClockwise() throws {
        // −1 turn is 270° clockwise, not a crash or a negative rotation value.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0], quarterTurns: -1)

        #expect(try PDFFixtures.pageRotations(at: out) == [270])
    }

    @Test func quarterTurnsWrapModuloFour() throws {
        // 5 turns ≡ 1 turn.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)

        try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0], quarterTurns: 5)

        #expect(try PDFFixtures.pageRotations(at: out) == [90])
    }

    @Test func rotationAddsToExistingPageRotation() throws {
        // A page already stored at 90° plus one turn lands at 180° — rotation is additive.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONLY"], rotations: [0: 90], to: src)

        try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0], quarterTurns: 1)

        #expect(try PDFFixtures.pageRotations(at: out) == [180])
    }

    @Test func rotationWrapsPastThreeSixty() throws {
        // 270° + one turn wraps to 0°, not 360°.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONLY"], rotations: [0: 270], to: src)

        try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0], quarterTurns: 1)

        #expect(try PDFFixtures.pageRotations(at: out) == [0])
    }

    @Test func zeroTurnsWritesAnUnrotatedCopy() throws {
        // A no-op rotation still produces a valid copy with page count and rotations intact.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0, 1], quarterTurns: 0)

        #expect(try PDFFixtures.pageCount(at: out) == 2)
        #expect(try PDFFixtures.pageRotations(at: out) == [0, 0])
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let src = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.rotate(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [0], quarterTurns: 1)
        }?.kind == "couldNotOpen")
    }

    @Test func outOfRangePageIndexThrowsInsteadOfBeingIgnored() throws {
        // Rotate used to silently skip a page index past the end (its loop simply never matched it),
        // so a typo'd selection rotated nothing with no error. It now validates the selection up
        // front like delete/extract/split and throws pageOutOfBounds naming the 1-based page.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.rotate(inputURL: src, outputURL: dir.url("out.pdf"), pageIndices: [5], quarterTurns: 1)
        }
        if case .pageOutOfBounds(let n)? = error { #expect(n == 6) } else {
            Issue.record("expected pageOutOfBounds(6), got \(String(describing: error))")
        }
    }
}
