import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// End-to-end behavior of the OCR operation against real Vision recognition: a rasterized (image-
/// only) page becomes searchable, the text layer lands where the printed words are, pages with
/// live text are skipped, and progress/cancellation plumbing works.
@Suite struct PDFToolkitOCRTests {

    /// A scanned-style fixture: real text rendered to a page, then rebuilt as an image-only PDF via
    /// the compress path — after which PDFKit extracts no text from it.
    private func writeScannedFixture(marker: String, in dir: FixtureDir) throws -> URL {
        let vector = dir.url("vector.pdf")
        try PDFFixtures.writePDF(markers: [marker], to: vector)
        let scanned = dir.url("scanned.pdf")
        try PDFFixtures.rasterize(vector, to: scanned)
        #expect(try PDFFixtures.pageTexts(at: scanned) == [""], "fixture must start with no text layer")
        return scanned
    }

    @Test func rasterizedPageBecomesSearchable() async throws {
        let dir = FixtureDir()
        let scanned = try writeScannedFixture(marker: "MARKERPAGE1", in: dir)
        let out = dir.url("searchable.pdf")

        let summary = try await VisionLane.run {
            try PDFToolkit.ocr(
                inputURL: scanned,
                outputURL: out,
                options: OCROptions(accurate: true, skipPagesWithText: true)
            )
        }

        #expect(summary.recognizedPages == 1)
        #expect(summary.skippedPages == 0)
        let text = try PDFFixtures.pageTexts(at: out).joined(separator: " ").uppercased()
        #expect(text.contains("MARKERPAGE1"), "recognized text must extract from the output, got: \(text)")
    }

    @Test func supportedLanguagesIncludeEnglish() {
        // The tool populates its language menu from this; every Mac ships at least an English model.
        let languages = PDFToolkit.supportedOCRLanguages()
        #expect(!languages.isEmpty)
        #expect(languages.contains { $0.hasPrefix("en") })
    }

    @Test func fastLanguagesAreAStrictSubsetOfAccurate() {
        // The tool must gate its language menu by level: Fast recognizes far fewer languages than
        // Accurate, and offering a Fast-unsupported language makes recognition silently return nothing.
        // The subset property is what guarantees the level-gated menu never offers an unusable language.
        let accurate = Set(PDFToolkit.supportedOCRLanguages(accurate: true))
        let fast = Set(PDFToolkit.supportedOCRLanguages(accurate: false))
        #expect(!fast.isEmpty)
        #expect(fast.isSubset(of: accurate))
        #expect(fast.count < accurate.count)
        #expect(fast.contains { $0.hasPrefix("en") }) // English recognizes at both levels
    }

    @Test func recognizesWithAnExplicitLanguage() async throws {
        // Naming a language (auto-detect off) must still recognize the page, not silently disable OCR.
        let dir = FixtureDir()
        let scanned = try writeScannedFixture(marker: "MARKERPAGE1", in: dir)
        let out = dir.url("searchable.pdf")

        let summary = try await VisionLane.run {
            try PDFToolkit.ocr(
                inputURL: scanned,
                outputURL: out,
                options: OCROptions(accurate: true, skipPagesWithText: true, recognitionLanguages: ["en-US"])
            )
        }

        #expect(summary.recognizedPages == 1)
        let text = try PDFFixtures.pageTexts(at: out).joined(separator: " ").uppercased()
        #expect(text.contains("MARKERPAGE1"), "recognized text must extract from the output, got: \(text)")
    }

    @Test func textLayerLandsWhereThePrintedWordsAre() async throws {
        let dir = FixtureDir()
        // The fixture draws its marker at x=72 with baseline at mid-page (y=396) in 24 pt type.
        let scanned = try writeScannedFixture(marker: "MARKERPAGE1", in: dir)
        let out = dir.url("searchable.pdf")

        _ = try await VisionLane.run {
            try PDFToolkit.ocr(inputURL: scanned, outputURL: out, options: OCROptions())
        }

        let doc = try #require(PDFDocument(url: out))
        let selections = doc.findString("MARKERPAGE1", withOptions: .caseInsensitive)
        let selection = try #require(selections.first, "the invisible layer must be findable")
        let page = try #require(selection.pages.first)
        let bounds = selection.bounds(for: page)
        // The compress rebuild keeps page geometry (612×792), so the recognized line must sit at
        // the drawn text's position — generous tolerances absorb raster/recognition wobble.
        #expect(abs(bounds.minX - 72) < 30, "x position off: \(bounds)")
        #expect(abs(bounds.midY - 404) < 30, "y position off: \(bounds)")
        #expect(bounds.width > 80, "selection should span the word: \(bounds)")
    }

    @Test func pagesWithLiveTextAreSkippedUntouched() throws {
        let dir = FixtureDir()
        let vector = dir.url("vector.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: vector)
        let out = dir.url("out.pdf")

        let summary = try PDFToolkit.ocr(
            inputURL: vector,
            outputURL: out,
            options: OCROptions(accurate: false, skipPagesWithText: true)
        )

        #expect(summary.recognizedPages == 0)
        #expect(summary.skippedPages == 2)
        // The vector text still extracts after the rebuild.
        #expect(try PDFFixtures.pageTexts(at: out) == ["MARKERPAGE1", "MARKERPAGE2"])
    }

    @Test func progressReportsEveryPageInOrder() throws {
        let dir = FixtureDir()
        let vector = dir.url("vector.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: vector)
        let out = dir.url("out.pdf")

        final class Progress: @unchecked Sendable {
            var pages: [Int] = []
            var totals: Set<Int> = []
        }
        let seen = Progress()
        _ = try PDFToolkit.ocr(
            inputURL: vector,
            outputURL: out,
            options: OCROptions(skipPagesWithText: true),
            progress: { page, total in
                seen.pages.append(page)
                seen.totals.insert(total)
            }
        )
        #expect(seen.pages == [1, 2, 3])
        #expect(seen.totals == [3])
    }

    @Test func cancellationAbortsBetweenPages() throws {
        let dir = FixtureDir()
        let vector = dir.url("vector.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: vector)

        #expect(throws: CancellationError.self) {
            _ = try PDFToolkit.ocr(
                inputURL: vector,
                outputURL: dir.url("out.pdf"),
                options: OCROptions(),
                isCancelled: { true }
            )
        }
    }

    @Test func corruptInputThrowsCouldNotOpen() throws {
        let dir = FixtureDir()
        let bad = dir.url("bad.pdf")
        try PDFFixtures.writeCorrupt(to: bad)

        let error = #expect(throws: PDFOperationError.self) {
            _ = try PDFToolkit.ocr(inputURL: bad, outputURL: dir.url("out.pdf"), options: OCROptions())
        }
        #expect(error?.kind == "couldNotOpen")
    }
}
