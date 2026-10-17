import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import PDFToolkitCore

/// No operation may write its result on top of its own input. Without the guard this was a silent
/// data-loss trap: `deletePages`/`rotate` mutate the loaded document and then `write(to:)` back over
/// the file they lazily read from, leaving an *unopenable* source; the CoreGraphics paths overwrite
/// the original with the transformed copy. Each test passes the same URL as input and output and
/// pins that the operation throws `outputMatchesInput` **and leaves the source byte-for-byte intact**,
/// because the guard runs before the source is ever opened.
@Suite struct PDFToolkitSamePathGuardTests {

    private func snapshot(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    /// Runs `body` with input == output == `src`, asserting it throws `outputMatchesInput` and that
    /// `src` is unchanged and still opens as a valid PDF afterward.
    private func expectGuarded(
        _ src: URL,
        _ body: (URL) throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let before = try snapshot(src)
        let error = #expect(throws: PDFOperationError.self, sourceLocation: sourceLocation) {
            try body(src)
        }
        #expect(error?.kind == "outputMatchesInput", sourceLocation: sourceLocation)
        #expect(try snapshot(src) == before, "source bytes changed", sourceLocation: sourceLocation)
        #expect(PDFDocument(url: src) != nil, "source no longer opens", sourceLocation: sourceLocation)
    }

    @Test func mergeRefusesToOverwriteAnInput() throws {
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: a)
        try PDFFixtures.writePDF(pageCount: 1, to: b)
        // The output collides with the *second* input, not the first — every input is protected.
        try expectGuarded(b) { out in try PDFToolkit.merge(inputURLs: [a, b], outputURL: out) }
    }

    @Test func splitNumbersAroundItsOwnSourceInsteadOfOverwriting() throws {
        // A source named exactly like a part the split would emit (`part-01.pdf`, zero-padded to the
        // two-digit width used for a two-part split) must not be clobbered. Split resolves every
        // part name through the never-overwrite numbering, so the collision succeeds harmlessly
        // instead of erroring: the part lands as `part-01 2.pdf` and the source is untouched.
        let dir = FixtureDir()
        let src = dir.url("part-01.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        let before = try snapshot(src)
        let outputs = try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "part", segments: [[0], [1]])
        #expect(outputs.map(\.lastPathComponent) == ["part-01 2.pdf", "part-02.pdf"])
        #expect(try snapshot(src) == before)
        #expect(PDFDocument(url: src) != nil)
    }

    @Test func extractRefusesToOverwriteTheSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        try expectGuarded(src) { out in try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [0, 2]) }
    }

    @Test func reorderRefusesToOverwriteTheSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        try expectGuarded(src) { out in try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [2, 1, 0]) }
    }

    @Test func deletePagesRefusesToOverwriteTheSource() throws {
        // The headline case: in-place delete over its own file used to yield an unopenable source.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: src)
        try expectGuarded(src) { out in try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [1]) }
        // Belt and suspenders: the source still has all three pages.
        #expect(try PDFFixtures.pageCount(at: src) == 3)
    }

    @Test func rotateRefusesToOverwriteTheSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        try expectGuarded(src) { out in
            try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0, 1], quarterTurns: 1)
        }
        #expect(try PDFFixtures.pageRotations(at: src) == [0, 0])
    }

    @Test func encryptRefusesToOverwriteTheSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        try expectGuarded(src) { out in try PDFToolkit.encrypt(inputURL: src, outputURL: out, password: "pw") }
    }

    @Test func removePasswordRefusesToOverwriteTheSource() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf"), locked = dir.url("locked.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        try PDFToolkit.encrypt(inputURL: plain, outputURL: locked, password: "pw")
        let before = try snapshot(locked)
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.removePassword(inputURL: locked, outputURL: locked, password: "pw")
        }
        #expect(error?.kind == "outputMatchesInput")
        #expect(try snapshot(locked) == before)
        // Still encrypted — the guard fired before any decrypt/rebuild.
        #expect(try #require(PDFDocument(url: locked)).isLocked)
    }

    @Test func compressRefusesToOverwriteTheSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)
        try expectGuarded(src) { out in try PDFToolkit.compress(inputURL: src, outputURL: out, quality: 0.5) }
        // Source text remains selectable — it was never rasterized in place.
        #expect(try PDFFixtures.pageTexts(at: src)[0].contains("MARKERPAGE1"))
    }

    @Test func watermarkRefusesToOverwriteTheSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)
        let options = WatermarkOptions(
            text: "DRAFT", fontSize: 48, opacity: 0.3, rotationDegrees: 45,
            red: 0.8, green: 0.1, blue: 0.1, tiled: false
        )
        try expectGuarded(src) { out in try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options) }
    }

    @Test func redactRefusesToOverwriteTheSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(markers: ["SECRET1"], to: src)
        let doc = try #require(PDFDocument(url: src))
        let rect = try #require(doc.page(at: 0)).bounds(for: .mediaBox)
        let mark = RedactionMark(pageIndex: 0, rect: rect)
        try expectGuarded(src) { out in
            try PDFToolkit.redact(
                inputURL: src, outputURL: out, marks: [mark],
                options: PDFRedactionExportOptions(stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 800)
            )
        }
        // The secret survives in the untouched source.
        #expect(try PDFFixtures.pageTexts(at: src)[0].contains("SECRET1"))
    }
}
