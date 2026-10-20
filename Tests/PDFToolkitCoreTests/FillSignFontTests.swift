import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// `FillSignText.font`: the face a typed run is drawn in, tried before the default chain — and
/// carried into the copy on both paths, drawn into the page (no form) and as a FreeText
/// annotation (a form, filled in place).
@Suite struct FillSignFontTests {

    @Test func aNamedFaceThisMacHasIsTaken() {
        #expect(PDFToolkit.font(size: 20, script: true, font: .named("SavoyeLetPlain")).fontName == "SavoyeLetPlain")
        #expect(PDFToolkit.font(size: 20, script: false, font: .named("Charter-Roman")).fontName == "Charter-Roman")
        #expect(PDFToolkit.font(size: 20, script: true, font: .named("Charter-Roman")).pointSize == 20)
    }

    /// A face that isn't installed, or a system font's private name (New York's), which `NSFont`
    /// won't open by name: the run's default face is used instead.
    @Test func aNameThisMacLacksFallsBackToTheDefaultFace() {
        for name in ["NoSuchFace-Regular", ".NewYork-Regular"] {
            #expect(PDFToolkit.font(size: 20, script: true, font: .named(name)).fontName
                    == PDFToolkit.scriptOrSystemFont(size: 20, script: true).fontName)
            #expect(PDFToolkit.font(size: 20, script: false, font: .named(name)).fontName
                    == NSFont.systemFont(ofSize: 20).fontName)
        }
    }

    @Test func theSystemDesignsAreTheSystemFontsOwn() {
        let rounded = PDFToolkit.font(size: 14, script: false, font: .systemRounded)
        #expect(rounded.fontName.localizedCaseInsensitiveContains("Rounded"))
        let mono = PDFToolkit.font(size: 14, script: false, font: .systemMonospaced)
        #expect(mono.isFixedPitch)
        #expect(mono.fontName != NSFont.systemFont(ofSize: 14).fontName)
    }

    @Test func noFontIsTodaysFace() {
        #expect(PDFToolkit.font(size: 18, script: true, font: nil).fontName
                == PDFToolkit.scriptOrSystemFont(size: 18, script: true).fontName)
        #expect(PDFToolkit.font(size: 18, script: false, font: nil).fontName == NSFont.systemFont(ofSize: 18).fontName)
    }

    private static func typed(_ font: FillSignFont?, script: Bool = true) -> FillSignItem {
        FillSignItem(pageIndex: 0, rect: CGRect(x: 72, y: 600, width: 320, height: 48),
                     content: .text(FillSignText(string: "Grace Hopper", fontSize: 24, red: 0, green: 0, blue: 0.6,
                                                 isScript: script, font: font)))
    }

    /// The face's own name embedded in the copy — `/BaseFont /AAAAAA+SavoyeLetPlain`.
    private static func embeds(_ name: String, in data: Data) -> Bool {
        data.range(of: Data("+\(name)".utf8)) != nil
    }

    @Test func aFlatCopyDrawsTheNamedFace() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        let savoye = try PDFToolkit.fillAndSignData(inputURL: src, items: [Self.typed(.named("SavoyeLetPlain"))])
        #expect(Self.embeds("SavoyeLetPlain", in: savoye))
        #expect(!Self.embeds("SnellRoundhand", in: savoye))
        let plain = try PDFToolkit.fillAndSignData(inputURL: src, items: [Self.typed(nil)])
        #expect(Self.embeds("SnellRoundhand", in: plain))
        #expect(try PDFFixtures.pageTexts(data: savoye)[0].contains("Grace Hopper"))
    }

    @Test func aFormsCopyNamesTheFaceInItsAnnotation() async throws {
        try await FormLane.run {
            let data = try PDFToolkit.fillFormData(inputURL: RealCorpus.acroFormFieldKinds.url, values: [:],
                                                   items: [Self.typed(.named("Charter-Roman"), script: false)])
            // Its appearance stream carries the face, which every reader paints. (Not the annotation's
            // `font` read back: PDFKit writes `/DA` as a name, not a string, and reads Helvetica.)
            let doc = try #require(PDFDocument(data: data))
            #expect(doc.page(at: 0)?.annotations.contains { $0.type == "FreeText" } == true)
            #expect(Self.embeds("Charter-Roman", in: data))
        }
    }
}
