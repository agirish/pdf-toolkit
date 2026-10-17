import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Pins the raster *resolution* Compress rebuilds pages at.
///
/// Compress used to clamp its raster to 1 pixel per PDF point — 72 dpi — for any page whose long edge
/// fell under the quality's pixel budget, which is every ordinary page size. A 600-dpi scan came back
/// at 72 dpi at *every* setting, including the highest: text turned to mush and the quality lever only
/// changed how hard that ruined bitmap was JPEG'd. These tests assert the emitted image dimensions
/// directly, because output *size* alone can't tell a sharp page from a blurry one.
@Suite struct PDFToolkitCompressResolutionTests {

    /// The pixel dimensions of every image the rebuilt PDF embeds. `CGPDFContext` writes the image
    /// XObject dictionaries as plain tokens, so the widths are readable straight out of the bytes —
    /// no PDF parser needed to answer "how many pixels did this page actually get?".
    private func embeddedImagePixels(_ data: Data) -> [(width: Int, height: Int)] {
        guard let text = String(data: data, encoding: .isoLatin1) else { return [] }
        let widths = numbers(after: "/Width ", in: text)
        let heights = numbers(after: "/Height ", in: text)
        return zip(widths, heights).map { (width: $0, height: $1) }
    }

    private func numbers(after key: String, in text: String) -> [Int] {
        text.components(separatedBy: key).dropFirst().compactMap {
            Int($0.prefix { $0.isNumber })
        }
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("compress-res-\(UUID().uuidString)-\(name)")
    }

    // MARK: - The 72-dpi regression

    @Test func highestQualityRendersWellAboveOnePixelPerPoint() throws {
        let src = tempURL("src.pdf")
        try PDFFixtures.writePDF(markers: ["A"], to: src)          // 612 × 792 pt Letter
        defer { try? FileManager.default.removeItem(at: src) }

        let data = try PDFToolkit.compressData(inputURL: src, quality: 0.85)
        let image = try #require(embeddedImagePixels(data).first)

        // 225 dpi at the top of the range: the long edge must be ~3.1× the page's 792 pt, and must
        // never fall back to the old 1 px/pt. A generous floor of 2× keeps the test about the bug
        // (72 dpi) rather than about the exact ramp constant.
        #expect(image.height > Int(792 * 2))
        #expect(image.height < Int(792 * 4))
    }

    @Test func loweringQualityLowersResolution() throws {
        let src = tempURL("src.pdf")
        try PDFFixtures.writePDF(markers: ["A"], to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        // Resolution is the primary size lever, so it must fall monotonically across the cards —
        // Best Quality → Balanced → Smallest File.
        let heights = try [0.85, 0.6, 0.35].map { q -> Int in
            let data = try PDFToolkit.compressData(inputURL: src, quality: q)
            return try #require(embeddedImagePixels(data).first).height
        }
        #expect(heights[0] > heights[1])
        #expect(heights[1] > heights[2])
    }

    // MARK: - Never upscale past the source

    @Test func doesNotRenderAboveTheSourcesOwnImageResolution() throws {
        let src = tempURL("src.pdf")
        let scan = tempURL("scan.pdf")
        try PDFFixtures.writePDF(markers: ["A"], to: src)
        // A low-resolution image-only page, i.e. a coarse scan: its pages carry a fixed pixel count.
        try PDFFixtures.rasterize(src, to: scan, quality: 0.2)
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: scan)
        }

        let nativeHeight = try #require(embeddedImagePixels(try Data(contentsOf: scan)).first).height
        let data = try PDFToolkit.compressData(inputURL: scan, quality: 1.0)
        let rebuiltHeight = try #require(embeddedImagePixels(data).first).height

        // Asking for 225 dpi from a page that only holds ~110 dpi of detail would spend bytes
        // re-encoding pixels that were never there. Rounding across the point-size round trip can
        // shift the edge by a pixel or two, so allow a hair of slack but no real upscale.
        #expect(rebuiltHeight <= nativeHeight + 2)
    }
}
