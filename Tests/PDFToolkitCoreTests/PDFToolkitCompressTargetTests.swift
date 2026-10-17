import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Target-size compression binary-searches a bounded ladder of qualities in `compressToTargetData`
/// and keeps the best-fitting result. These end-to-end tests exercise the real shipped sweep against
/// live PDFs: a generous target produces a valid file, an impossible target still emits the smallest
/// result, the output never exceeds the source, an already-small source passes through untouched, and
/// the guard/error cases (self-overwrite, unreadable source) throw.
@Suite struct PDFToolkitCompressTargetTests {

    @Test func generousTargetProducesAValidPDF() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        try PDFToolkit.compressToTarget(inputURL: src, outputURL: out, targetBytes: 5_000_000)

        #expect(try PDFFixtures.pageCount(at: out) == 2)
    }

    @Test func unreachableTargetStillWritesTheSmallestResult() throws {
        // A 1-byte budget can't be met, but the tool must still emit the most-compressed attempt
        // rather than fail — a valid 2-page PDF comes out.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: src)

        try PDFToolkit.compressToTarget(inputURL: src, outputURL: out, targetBytes: 1)

        #expect(try PDFFixtures.pageCount(at: out) == 2)
    }

    @Test func unreadableSourceThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.compressToTarget(inputURL: bad, outputURL: dir.url("out.pdf"), targetBytes: 1000)
        }?.kind == "couldNotOpen")
    }

    @Test func refusesToOverwriteItsOwnSource() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.compressToTarget(inputURL: src, outputURL: src, targetBytes: 1000)
        }?.kind == "outputMatchesInput")
    }

    @Test func aSourceAlreadyUnderTheTargetPassesThroughUnchanged() throws {
        // Rasterizing a file that already fits can only lose quality (and often grows it) — the
        // source bytes must pass through untouched, keeping vector text extractable.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["KEEPME"], to: src)
        let sourceBytes = try Data(contentsOf: src)

        try PDFToolkit.compressToTarget(inputURL: src, outputURL: out, targetBytes: sourceBytes.count + 10_000)

        #expect(try Data(contentsOf: out) == sourceBytes)
        #expect(try PDFFixtures.pageTexts(at: out)[0].contains("KEEPME"))
    }

    @Test func neverEmitsAFileLargerThanTheSource() throws {
        // A lean text PDF inflates at every raster rung. With an unreachable target the old code
        // shipped the smallest attempt anyway — several times the original's size, reported as
        // success. The output must never exceed the input.
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["TINY"], to: src)
        let sourceCount = try Data(contentsOf: src).count

        try PDFToolkit.compressToTarget(inputURL: src, outputURL: out, targetBytes: 1)

        let outCount = try Data(contentsOf: out).count
        #expect(outCount <= sourceCount)
    }
}
