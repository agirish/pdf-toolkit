import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// Find & redact locates text (literal or preset regex), turns each occurrence into a redaction
/// region in PDF user space, and hands it to the same pipeline a hand-drawn mark uses. These tests
/// pin: the returned rectangles land on the matched text and nowhere else (verified through the real
/// redaction, by pixel), the located geometry is rotation-invariant (so rotated pages need no special
/// case), the preset patterns catch the values they should, and pages with no text layer are surfaced
/// rather than silently skipped.
@Suite struct PDFToolkitFindRedactTests {

    /// A low raster ceiling keeps the redaction bitmaps fast in tests.
    private let fastOptions = PDFRedactionExportOptions(
        stripAnnotationsFromUnredactedPages: false, maxPixelDimension: 800
    )

    // MARK: - Regex presets (unit)

    /// Builds a preset's compiled regex and applies the same semantic filter (`acceptsMatch`) the
    /// matcher uses in its collection step — so the card Luhn check is exercised here, not just the
    /// raw shape — and returns the substrings the preset would actually mark in `text`.
    private func matches(_ pattern: FindRedactPattern, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern.regexPattern, options: [.caseInsensitive])
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .filter { pattern.acceptsMatch?($0) ?? true }
    }

    @Test func emailPresetCatchesAddressesAndIgnoresProse() throws {
        let found = try matches(.email, in: "Write jane.doe+tag@work.co or bob_99@x.io — not http://x.io or @handle.")
        #expect(found == ["jane.doe+tag@work.co", "bob_99@x.io"])
    }

    /// The local part must cover the full unquoted (atext) set. An apostrophe is the common real case:
    /// omitting it made "o'brien.pat@work.co" match only "brien.pat@work.co" — a box that *looks* like
    /// a full redaction while leaking the name, worse than a clean miss.
    @Test func emailPresetCoversApostropheAndOtherAtextInTheLocalPart() throws {
        #expect(try matches(.email, in: "mail o'brien.pat@work.co please") == ["o'brien.pat@work.co"])
        #expect(try matches(.email, in: "raw a!#$%&'*+/=?^_`{|}~-x@sub.example.com end")
            == ["a!#$%&'*+/=?^_`{|}~-x@sub.example.com"])
    }

    @Test func ssnPresetMatchesDashedSpacedAndSolidNines() throws {
        #expect(try matches(.ssn, in: "SSN 123-45-6789 on file") == ["123-45-6789"])
        // Spaced and fully unformatted SSNs must match too — the old dashes-only pattern missed both.
        #expect(try matches(.ssn, in: "SSN 123 45 6789 on file") == ["123 45 6789"])
        #expect(try matches(.ssn, in: "SSN 123456789 on file") == ["123456789"])
        // A bare 9-digit run is deliberately caught: it may be an unformatted SSN, and the tool prefers
        // a box the reviewer deletes to a leaked identifier.
        #expect(try matches(.ssn, in: "ref 987654321 end") == ["987654321"])
        // But a 10-digit run and a mis-grouped run (2-3-4, 4-2-4) are not SSN-shaped and must not match.
        #expect(try matches(.ssn, in: "acct 1234-56-7890 and 12-345-6789").isEmpty)
    }

    @Test func phonePresetMatchesUSAndInternationalFormats() throws {
        #expect(try matches(.phone, in: "call (415) 555-0132 today") == ["(415) 555-0132"])
        #expect(try matches(.phone, in: "or +1 415.555.0132") == ["+1 415.555.0132"])
        #expect(try matches(.phone, in: "or 4155550132 works") == ["4155550132"])
        // International numbers written with an explicit +<country code> must match in full — a partial
        // match would leave part of the number un-redacted.
        #expect(try matches(.phone, in: "ring +44 20 7946 0958 now") == ["+44 20 7946 0958"])
        #expect(try matches(.phone, in: "on +91 98765 43210 daily") == ["+91 98765 43210"])
    }

    @Test func cardPresetMatchesThirteenThroughNineteenDigitShapesAndFiltersByLuhn() throws {
        // Existing valid shapes still match (all Luhn-valid test numbers).
        #expect(try matches(.card, in: "Visa 4111 1111 1111 1111 exp") == ["4111 1111 1111 1111"])
        #expect(try matches(.card, in: "Amex 3782 822463 10005 ok") == ["3782 822463 10005"])
        // Shapes the old fours-only pattern missed: 13-digit, dot-separated 14-digit Diners, 19-digit.
        #expect(try matches(.card, in: "old 4222222222222 card") == ["4222222222222"])
        #expect(try matches(.card, in: "dc 3056.930902.5904 x") == ["3056.930902.5904"])
        #expect(try matches(.card, in: "big 4000 0000 0000 0000 006 y") == ["4000 0000 0000 0000 006"])
        // Too-short runs never reach the Luhn filter — the shape rejects them.
        #expect(try matches(.card, in: "order 12345 shipped").isEmpty)
        // A 16-digit run that fails the Luhn checksum (e.g. an invoice number) is rejected by the
        // filter even though its shape matches — this is the false-positive guard.
        #expect(try matches(.card, in: "inv 1234 5678 9012 3456 x").isEmpty)
    }

    // MARK: - Literal search geometry (end-to-end, unrotated)

    @Test func literalMatchMarksTheTextAndRedactionBlacksOutOnlyThere() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        // Top line is exactly the email; a different line sits at the bottom.
        try PDFFixtures.writeTwoZonePage(top: "agent@example.com", bottom: "PUBLICLINE", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("agent@example.com"))
        #expect(result.matchCount == 1)
        #expect(result.pageCount == 1)
        let auto = result.marks()
        #expect(auto.count == 1)
        let mark = try #require(auto.first)
        #expect(mark.pageIndex == 0)
        #expect(mark.origin == .autoMatch)
        // The rect sits on the top line (baseline y ≈ 692), starts near the left margin, and spans
        // the email — not the whole page.
        #expect(mark.rect.midY > 640)
        #expect(mark.rect.minX < 90)
        #expect(mark.rect.width > 60)
        #expect(mark.rect.width < 300)

        // Apply the real redaction with exactly that mark.
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: auto, options: fastOptions)

        // The email text is gone (page rasterized) — not selectable, not recoverable.
        #expect(!(try PDFFixtures.pageTexts(at: out)[0].contains("agent@example.com")))

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        // Solid black exactly where the match was located.
        #expect(brightness(mark.rect.midX, mark.rect.midY) < 0.2)
        // The bottom line was not marked, so its glyphs still render (dark strokes present).
        let bottomGlyphs = PDFFixtures.darkestSample(
            brightness, xRange: stride(from: 76, through: 150, by: 2), yValues: [82, 86, 90]
        )
        #expect(bottomGlyphs < 0.5)
        // The empty middle of the page stayed white — redaction did not spill past the match.
        #expect(brightness(400, 400) > 0.7)
    }

    @Test func literalMatchInsideAWordIsBoundedToTheMatchNotTheWholeLine() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "from agent@example.com now", bottom: "PUBLICLINE", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("agent@example.com"))
        let mark = try #require(result.marks().first)
        // If the character-range → selection mapping were off, the box would start at the line origin
        // and cover "from"; the leading word means a correct mapping starts well to the right of x72.
        #expect(mark.rect.minX > 95)
        #expect(mark.rect.midY > 640)
    }

    /// Two separate matches on the *same* visual line must produce two separate marks with distinct,
    /// side-by-side rectangles. The per-match line-bounds path (`selectionsByLine` → `bounds(for:)`,
    /// one rect set per matched range) was otherwise only exercised by single-match or multi-line cases,
    /// so a bug that merged same-line hits into one box — over-redacting the gap between them — would
    /// have gone unnoticed.
    @Test func twoMatchesOnOneLineYieldTwoDistinctRects() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "a@x.io b@y.io", bottom: "PUBLICLINE", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .pattern(.email))
        #expect(result.matchCount == 2)
        let marks = result.marks().sorted { $0.rect.minX < $1.rect.minX }
        #expect(marks.count == 2)
        // Both boxes sit on the top line, not the bottom one…
        #expect(marks.allSatisfy { $0.rect.midY > 640 })
        // …and they are two separate side-by-side boxes: the left one ends before the right one's
        // centre, so the per-match rects were not merged into one line-spanning box.
        #expect(marks[0].rect.maxX < marks[1].rect.midX)
        #expect(marks[1].rect.minX - marks[0].rect.minX > 40)
    }

    @Test func literalSearchIsCaseInsensitiveAndFindsEveryOccurrence() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "Smith and SMITH", bottom: "or smith again", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("smith"))
        #expect(result.matchCount == 3)
        #expect(result.pageCount == 1)
    }

    @Test func noMatchLeavesNoMarks() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "nothing here", bottom: "or here", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("absent"))
        #expect(result.matchCount == 0)
        #expect(result.marks().isEmpty)
    }

    // MARK: - Rotation

    /// The load-bearing geometry guarantee: `PDFSelection.bounds(for:)` returns the match rect in the
    /// page's *unrotated* user space — the space the redaction fill expects — so the very same content
    /// yields the very same rect no matter the page's /Rotate. If this held display-space coordinates
    /// instead, the rotated rect's axes would swap and this would fail.
    @Test func locatedRectIsInvariantToPageRotation() throws {
        let dir = FixtureDir()
        let upright = dir.url("upright.pdf"), rotated = dir.url("rotated.pdf")
        try PDFFixtures.writePDF(markers: ["agent@example.com"], to: upright)
        try PDFFixtures.writePDF(markers: ["agent@example.com"], rotations: [0: 90], to: rotated)

        let a = try #require(PDFToolkit.findRedactionMarks(inputURL: upright, query: .literal("agent@example.com")).marks().first)
        let b = try #require(PDFToolkit.findRedactionMarks(inputURL: rotated, query: .literal("agent@example.com")).marks().first)

        let tol: CGFloat = 1.0
        #expect(abs(a.rect.minX - b.rect.minX) < tol)
        #expect(abs(a.rect.minY - b.rect.minY) < tol)
        #expect(abs(a.rect.width - b.rect.width) < tol)
        #expect(abs(a.rect.height - b.rect.height) < tol)
    }

    @Test func redactionBlacksOutTheMatchOnARotatedPage() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf"), out = dir.url("out.pdf")
        // /Rotate 90 US-Letter displays landscape (792×612); the marker's native baseline (72,396)
        // maps to a vertical run near display x≈402 descending from y≈540 (pinned by the redact suite).
        try PDFFixtures.writePDF(markers: ["agent@example.com"], rotations: [0: 90], to: src)

        let auto = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("agent@example.com")).marks()
        #expect(auto.count == 1)
        try PDFToolkit.redact(inputURL: src, outputURL: out, marks: auto, options: fastOptions)

        #expect(try PDFFixtures.pageSize(at: out) == CGSize(width: 792, height: 612))
        #expect(!(try PDFFixtures.pageTexts(at: out)[0].contains("agent@example.com")))

        let brightness = try PDFFixtures.brightnessSampler(at: out)
        // Over the email's displayed glyph column, the samples are now a solid black block (a
        // mis-placed box would leave visible glyphs, so most samples would be white).
        var total = 0, black = 0
        for x in stride(from: CGFloat(398), through: 406, by: 4) {
            for y in stride(from: CGFloat(400), through: 535, by: 5) {
                total += 1
                if brightness(x, y) < 0.2 { black += 1 }
            }
        }
        #expect(Double(black) / Double(total) > 0.85)
        // A corner far from the text stayed white — the whole page was not blacked.
        #expect(brightness(720, 560) > 0.7)
    }

    // MARK: - Presets end-to-end

    @Test func emailPresetMarksEveryAddressInTheDocument() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "jane.doe@work.co", bottom: "bob_99@x.io", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .pattern(.email))
        #expect(result.matchCount == 2)
        #expect(result.marks().allSatisfy { $0.origin == .autoMatch })
    }

    @Test func ssnPresetMarksTheDashedNumber() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "SSN 123-45-6789", bottom: "ref 001", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .pattern(.ssn))
        #expect(result.matchCount == 1)
    }

    // MARK: - No text layer

    @Test func pagesWithoutTextAreReportedNotSilentlySkipped() throws {
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        // Page 1 carries text; page 2 is blank (no text layer) — the stand-in for an un-recognized scan.
        try PDFFixtures.writePDF(markers: ["hello agent@example.com", ""], to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .pattern(.email))
        #expect(result.matchCount == 1)
        #expect(result.pagesWithoutText == [1])
    }

    @Test func locatableMatchesReportNoUnlocatableCount() throws {
        // Every hit here has real on-page geometry, so the undercount guard must stay at zero — it
        // only fires when PDFKit yields empty bounds for a match it did find in the text layer.
        let dir = FixtureDir()
        let src = dir.url("src.pdf")
        try PDFFixtures.writeTwoZonePage(top: "agent@example.com", bottom: "PUBLICLINE", to: src)

        let result = try PDFToolkit.findRedactionMarks(inputURL: src, query: .literal("agent@example.com"))
        #expect(result.matchCount == 1)
        #expect(result.unlocatableMatches == 0)
    }

    // MARK: - Guards

    @Test func lockedInputIsRefused() throws {
        let dir = FixtureDir()
        let src = dir.url("locked.pdf")
        try PDFFixtures.writePDF(pageCount: 1, to: src)
        let doc = try #require(PDFDocument(url: src))
        let locked = dir.url("locked-enc.pdf")
        #expect(doc.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))

        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.findRedactionMarks(inputURL: locked, query: .literal("MARKERPAGE1"))
        }
    }
}
