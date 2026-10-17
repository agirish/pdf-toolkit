import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import PDFToolkitCore

/// Every operation writes its result to a *separate* `outputURL`; the input is only ever read. These
/// tests pin that contract the hard way — they snapshot the raw bytes of each source file before the
/// operation and assert they are byte-for-byte identical afterward. A regression that wrote back
/// through the input (or that let PDFKit's lazy page references mutate the on-disk source) would flip
/// one of these, which the per-page behavior suites cannot catch because they only inspect the output.
@Suite struct PDFToolkitSourceIntegrityTests {

    /// Raw bytes of a file on disk, for exact before/after comparison.
    private func snapshot(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    // MARK: - Single-source operations

    @Test func mergeLeavesEveryInputUnchanged() throws {
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), b = dir.url("b.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ALPHA", "BETA"], to: a)
        try PDFFixtures.writePDF(markers: ["GAMMA"], to: b)
        let beforeA = try snapshot(a), beforeB = try snapshot(b)

        try PDFToolkit.merge(inputURLs: [a, b], outputURL: out)

        #expect(try snapshot(a) == beforeA)
        #expect(try snapshot(b) == beforeB)
    }

    @Test func mergeWithARepeatedInputLeavesItUnchanged() throws {
        // The same file listed twice is opened twice; neither pass may write back through it.
        let dir = FixtureDir()
        let a = dir.url("a.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONE", "TWO"], to: a)
        let before = try snapshot(a)

        try PDFToolkit.merge(inputURLs: [a, a], outputURL: out)

        #expect(try snapshot(a) == before)
    }

    @Test func splitLeavesTheSourceUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 4, to: src)
        let before = try snapshot(src)

        _ = try PDFToolkit.split(inputURL: src, into: dir.url, baseName: "part", segments: [[0, 1], [2, 3]])

        #expect(try snapshot(src) == before)
    }

    @Test func extractLeavesTheSourceUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)
        let before = try snapshot(src)

        try PDFToolkit.extract(inputURL: src, outputURL: out, pageIndices: [2, 0])

        #expect(try snapshot(src) == before)
    }

    @Test func reorderLeavesTheSourceUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)
        let before = try snapshot(src)

        try PDFToolkit.reorder(inputURL: src, outputURL: out, order: [2, 1, 0])

        #expect(try snapshot(src) == before)
    }

    @Test func deletePagesLeavesTheSourceUnchanged() throws {
        // Delete mutates the *in-memory* PDFDocument (removePage) before writing elsewhere — this pins
        // that the mutation never reaches the file the document was loaded from.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["P1", "P2", "P3"], to: src)
        let before = try snapshot(src)

        try PDFToolkit.deletePages(inputURL: src, outputURL: out, pageIndices: [1])

        #expect(try snapshot(src) == before)
        // And the source still reads as its original three pages.
        #expect(try PDFFixtures.pageCount(at: src) == 3)
    }

    @Test func rotateLeavesTheSourceUnchanged() throws {
        // Rotate sets page.rotation on the loaded document — again, must not persist to the source.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        let before = try snapshot(src)

        try PDFToolkit.rotate(inputURL: src, outputURL: out, pageIndices: [0, 1], quarterTurns: 1)

        #expect(try snapshot(src) == before)
        #expect(try PDFFixtures.pageRotations(at: src) == [0, 0])
    }

    @Test func encryptLeavesThePlainSourceUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)
        let before = try snapshot(src)

        try PDFToolkit.encrypt(inputURL: src, outputURL: out, password: "secret")

        #expect(try snapshot(src) == before)
        // The source is still openable with no password.
        let reopened = try #require(PDFDocument(url: src))
        #expect(!reopened.isEncrypted)
    }

    @Test func removePasswordLeavesTheLockedSourceUnchanged() throws {
        let dir = FixtureDir()
        let plain = dir.url("plain.pdf"), locked = dir.url("locked.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        try PDFToolkit.encrypt(inputURL: plain, outputURL: locked, password: "pw")
        let before = try snapshot(locked)

        try PDFToolkit.removePassword(inputURL: locked, outputURL: out, password: "pw")

        #expect(try snapshot(locked) == before)
        // The source remains encrypted/locked — removal produced a new file, it did not decrypt in place.
        let reopened = try #require(PDFDocument(url: locked))
        #expect(reopened.isLocked)
    }

    @Test func compressLeavesTheSourceUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1", "MARKERPAGE2"], to: src)
        let before = try snapshot(src)

        try PDFToolkit.compress(inputURL: src, outputURL: out, quality: 0.5)

        #expect(try snapshot(src) == before)
        // The source text is still selectable — only the output was rasterized.
        let texts = try PDFFixtures.pageTexts(at: src)
        #expect(texts[0].contains("MARKERPAGE1"))
    }

    @Test func watermarkLeavesTheSourceUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)
        let before = try snapshot(src)

        let options = WatermarkOptions(
            text: "DRAFT", fontSize: 48, opacity: 0.3, rotationDegrees: 45,
            red: 0.8, green: 0.1, blue: 0.1, tiled: true
        )
        try PDFToolkit.watermark(inputURL: src, outputURL: out, options: options)

        #expect(try snapshot(src) == before)
    }

    @Test func redactLeavesTheSourceUnchanged() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["SECRET1", "PUBLIC2"], to: src)
        let before = try snapshot(src)

        let doc = try #require(PDFDocument(url: src))
        let rect = try #require(doc.page(at: 0)).bounds(for: .mediaBox)
        let mark = RedactionMark(pageIndex: 0, rect: rect)
        try PDFToolkit.redact(
            inputURL: src, outputURL: out, marks: [mark],
            options: PDFRedactionExportOptions(stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 800)
        )

        #expect(try snapshot(src) == before)
        // The secret is still fully present in the untouched source (redaction only affects the copy).
        let texts = try PDFFixtures.pageTexts(at: src)
        #expect(texts[0].contains("SECRET1"))
    }
}
