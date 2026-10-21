import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// `FillSignPatch`: a filled rectangle drawn into the page, under the page's text runs and
/// signatures whatever the items' order — the patch a correction's new words sit on. It covers the
/// old words; it does not remove them.
@Suite struct FillSignPatchTests {

    private static func patch(_ rect: CGRect, page: Int = 0, red: CGFloat = 1, green: CGFloat = 1,
                              blue: CGFloat = 1) -> FillSignItem {
        FillSignItem(pageIndex: page, rect: rect, content: .patch(FillSignPatch(red: red, green: green, blue: blue)))
    }

    private static func text(_ string: String, rect: CGRect, page: Int = 0) -> FillSignItem {
        FillSignItem(pageIndex: page, rect: rect,
                     content: .text(FillSignText(string: string, fontSize: 24, red: 0, green: 0, blue: 0)))
    }

    /// Where `string` is on page `index` of `url`, in that page's space.
    private static func bounds(of string: String, in url: URL, page index: Int = 0) throws -> CGRect {
        let doc = try #require(PDFDocument(url: url))
        let page = try #require(doc.page(at: index))
        let hit = try #require(doc.findString(string, withOptions: []).first)
        return hit.bounds(for: page)
    }

    /// The darkest point over a grid inside `rect`.
    private static func darkest(_ sampler: (CGFloat, CGFloat) -> CGFloat, in rect: CGRect) -> CGFloat {
        PDFFixtures.darkestSample(sampler, xRange: stride(from: rect.minX + 1, through: rect.maxX - 1, by: 1),
                                  yValues: Array(stride(from: rect.minY + 1, through: rect.maxY - 1, by: 1)))
    }

    @Test func aPatchHidesTheWordsUnderItButLeavesThemInTheText() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)
        let words = try Self.bounds(of: "MARKERPAGE1", in: src)
        #expect(Self.darkest(try PDFFixtures.brightnessSampler(at: src), in: words) < 0.3)

        try PDFToolkit.fillAndSign(inputURL: src, outputURL: out, items: [Self.patch(words.insetBy(dx: -1, dy: -1))])

        #expect(Self.darkest(try PDFFixtures.brightnessSampler(at: out), in: words) > 0.95)
        // Covered, not removed — the reason an app has to say so.
        #expect(try PDFFixtures.pageTexts(at: out)[0].contains("MARKERPAGE1"))
    }

    @Test func aPatchIsDrawnInItsColour() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)
        let rect = CGRect(x: 300, y: 600, width: 80, height: 40)

        try PDFToolkit.fillAndSign(inputURL: src, outputURL: out,
                                   items: [Self.patch(rect, red: 1, green: 0.5, blue: 0)])

        // Rendered into an sRGB bitmap, as an app samples a page: a thumbnail's TIFF is in the
        // display's space and moved the colour by a tenth.
        let doc = try #require(PDFDocument(url: out))
        let page = try #require(doc.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let ctx = try #require(CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: box.size))
        page.draw(with: .mediaBox, to: ctx)
        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        // Bottom-up rows: a bitmap context's memory starts at the TOP row.
        func rgb(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            let offset = (Int(box.height) - 1 - Int(y)) * ctx.bytesPerRow + Int(x) * 4
            return (CGFloat(pixels[offset]) / 255, CGFloat(pixels[offset + 1]) / 255, CGFloat(pixels[offset + 2]) / 255)
        }
        let inside = rgb(rect.midX, rect.midY)
        #expect(abs(inside.0 - 1) < 0.02)
        #expect(abs(inside.1 - 0.5) < 0.02)
        #expect(inside.2 < 0.02)
        // Outside it, the page is as it was.
        let outside = rgb(rect.maxX + 20, rect.midY)
        #expect(outside.0 > 0.98 && outside.2 > 0.98)
    }

    /// **The patch goes under the words whichever order the items came in** — a correction listed
    /// text first still shows its text.
    @Test func aPatchListedAfterItsWordsIsStillDrawnUnderThem() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["MARKERPAGE1"], to: src)
        let rect = CGRect(x: 300, y: 600, width: 220, height: 40)

        try PDFToolkit.fillAndSign(inputURL: src, outputURL: out,
                                   items: [Self.text("NEWWORDS", rect: rect), Self.patch(rect, red: 1, green: 1, blue: 0)])

        let sampler = try PDFFixtures.brightnessSampler(at: out)
        #expect(Self.darkest(sampler, in: rect) < 0.3)
        #expect(try PDFFixtures.pageTexts(at: out)[0].contains("NEWWORDS"))
    }

    /// On a `/Rotate 90` page the copy is emitted upright; the patch, in page space, still lands on
    /// the words it was placed over.
    @Test func aPatchCoversItsWordsOnARotatedPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        try PDFFixtures.writePDF(markers: ["ONLY"], rotations: [0: 90], to: src)
        let words = try Self.bounds(of: "ONLY", in: src)

        try PDFToolkit.fillAndSign(inputURL: src, outputURL: out, items: [Self.patch(words.insetBy(dx: -1, dy: -1))])

        let moved = try Self.bounds(of: "ONLY", in: out)
        #expect(Self.darkest(try PDFFixtures.brightnessSampler(at: out), in: moved) > 0.95)
    }

    @Test func aPatchWithNoAreaIsNothingToBake() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        #expect(!Self.patch(CGRect(x: 10, y: 10, width: 0, height: 20)).hasInk)
        #expect(Self.patch(CGRect(x: 10, y: 10, width: 4, height: 4)).hasInk)
        #expect(#expect(throws: PDFOperationError.self) {
            try PDFToolkit.fillAndSignData(inputURL: src, items: [Self.patch(CGRect(x: 10, y: 10, width: 30, height: 0))])
        }?.kind == "noFillSignItems")
    }

    /// On a form filled in place a patch is a borderless Square annotation in its colour, added
    /// before the words placed over it so they are drawn on top.
    @Test func aFormsCopyAddsThePatchAsASquareUnderTheWords() async throws {
        try await FormLane.run {
            let rect = CGRect(x: 300, y: 600, width: 220, height: 40)
            let data = try PDFToolkit.fillFormData(
                inputURL: RealCorpus.acroFormFieldKinds.url, values: [:],
                items: [Self.text("NEWWORDS", rect: rect), Self.patch(rect, red: 1, green: 1, blue: 0)])
            let doc = try #require(PDFDocument(data: data))
            let annotations = try #require(doc.page(at: 0)).annotations
            let square = try #require(annotations.firstIndex { $0.type == "Square" })
            let words = try #require(annotations.lastIndex { $0.type == "FreeText" })
            #expect(square < words)
            let fill = try #require(annotations[square].interiorColor?.usingColorSpace(.sRGB))
            #expect(fill.redComponent > 0.95 && fill.greenComponent > 0.95 && fill.blueComponent < 0.05)
            #expect(annotations[square].border?.lineWidth == 0)
        }
    }
}
