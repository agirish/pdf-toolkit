import CoreGraphics
import Foundation
import PDFKit

/// A built-in pattern the Find & redact search can auto-mark. Each case is a regular expression run
/// over every page's extracted text; matches become redaction regions the user reviews before
/// exporting. The patterns are deliberately permissive-but-anchored: they favor catching a real
/// value (an email, an SSN) over rejecting an oddly formatted one, because a human confirms every
/// mark and the cost of a false negative — a leaked identifier — is worse than a false positive the
/// user simply deletes.
public enum FindRedactPattern: String, CaseIterable, Identifiable, Sendable {
    case email
    case ssn
    case phone
    case card

    public var id: String { rawValue }

    /// Chip label on the Redact screen.
    public var displayName: String {
        switch self {
        case .email: return "Emails"
        case .ssn: return "SSNs"
        case .phone: return "Phone numbers"
        case .card: return "Card numbers"
        }
    }

    public var symbolName: String {
        switch self {
        case .email: return "at"
        case .ssn: return "person.text.rectangle"
        case .phone: return "phone"
        case .card: return "creditcard"
        }
    }

    /// The ICU regular expression. Raw strings keep the backslashes literal. `(?<!\d)…(?!\d)` guards
    /// stop a phone/card pattern from biting a slice out of a longer digit run. The presets favor over-
    /// catching (a human deletes a stray box) over under-catching (a leaked identifier), per the type's
    /// header note — so shapes stay broad and the one filter that could hide a real value, a partial
    /// email, is closed by covering the full local-part character set.
    var regexPattern: String {
        switch self {
        case .email:
            // Local part is the full RFC-5322 unquoted set (atext), including `'`. The old class
            // omitted `'` and others, so "o'brien.pat@work.co" matched only "brien.pat@work.co" — a
            // partial box that *looks* fully redacted, the worst outcome for a redaction tool.
            return #"[A-Za-z0-9.!#$%&'*+/=?^_`|~\{\}\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        case .ssn:
            // 9 digits grouped 3-2-4 with the separators optional, so dashed (123-45-6789), spaced
            // (123 45 6789), and solid (123456789) SSNs all match. A bare 9-digit run is caught too —
            // an unformatted SSN is exactly what the false-negative-averse philosophy wants marked.
            return #"(?<!\d)\d{3}[-\s]?\d{2}[-\s]?\d{4}(?!\d)"#
        case .phone:
            // Two shapes: the US number (optional +1, optional area-code parens, 3-3-4 grouping), or an
            // international number written with an explicit `+<country code>` followed by digit groups
            // separated by spaces/dots/dashes — so +44 20 7946 0958 and +91 98765 43210 are caught, not
            // just US formats.
            return #"(?<!\d)(?:(?:\+?1[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}|\+\d{1,3}[\s.\-]?\d{1,4}(?:[\s.\-]?\d{1,4}){1,4})(?!\d)"#
        case .card:
            // 13–19 digits with optional space/dash/dot separators — covers 13-digit Visa, 14-digit
            // Diners, 15-digit Amex, 16-digit, and 19-digit Visa/Maestro/UnionPay, dotted or grouped.
            // The shape alone is permissive, so `acceptsMatch` runs a Luhn check to drop non-card digit
            // runs (invoice/order numbers).
            return #"(?<!\d)(?:\d[ \-.]?){12,18}\d(?!\d)"#
        }
    }

    /// A semantic check applied to each raw regex hit before it becomes a redaction mark, or `nil` to
    /// accept every hit. Cards run a Luhn (mod-10) checksum: the 13–19-digit shape matches any long
    /// digit run, and the checksum narrows that to plausible card numbers so invoice/order/tracking
    /// numbers don't blanket the page with marks. The other presets trust their (already anchored) shape.
    var acceptsMatch: (@Sendable (String) -> Bool)? {
        switch self {
        case .card: return { FindRedactPattern.passesLuhnChecksum($0) }
        case .email, .ssn, .phone: return nil
        }
    }

    /// Standard Luhn (mod-10) checksum over the ASCII digits in `text`, ignoring any separators. Real
    /// card numbers satisfy it; most arbitrary long digit runs do not. It is only a checksum, not a
    /// brand/prefix validator — a false positive here is a box the reviewer deletes, which the tool's
    /// philosophy prefers to a missed card.
    private static func passesLuhnChecksum(_ text: String) -> Bool {
        let digits = text.compactMap { $0.isASCII && $0.isNumber ? $0.wholeNumberValue : nil }
        guard !digits.isEmpty else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }
}

/// What Find & redact should search for. A plain literal substring the user typed, or a preset
/// pattern. Plain values only, so the query crosses onto the PDF serial queue.
public enum FindRedactQuery: Sendable, Equatable {
    /// The exact text the user typed. Matched case-insensitively — names and emails vary in casing.
    case literal(String)
    case pattern(FindRedactPattern)

    /// Human phrase for the "N matches for …" summary and the Activity Log.
    public var describedTarget: String {
        switch self {
        case .literal(let text): return "“\(text)”"
        case .pattern(let pattern): return pattern.displayName.lowercased()
        }
    }
}

/// One matched occurrence: the page it sits on and the rectangle(s) covering it. A match that wraps
/// across a line break yields more than one rect (one per visual line), so a redaction box never
/// spans the gap between lines.
struct FindRedactMatch: Sendable {
    let pageIndex: Int
    let rects: [CGRect]
}

/// The outcome of one Find & redact scan.
public struct FindRedactResult: Sendable {
    /// Every occurrence found, in page then reading order.
    var matches: [FindRedactMatch]
    /// Zero-based indices of pages whose text layer was empty. Search cannot see these (they may be
    /// un-recognized scans), so the caller surfaces them rather than letting matches hide silently.
    public var pagesWithoutText: [Int]
    /// Occurrences whose text was matched but whose on-page rectangle came back empty — PDFKit gave
    /// no selection geometry, or the match clipped entirely into a cropped-out margin — so no box
    /// could be placed. Keyed by zero-based page index, because WHICH page carries one decides
    /// whether anything leaks: a page with marks is rasterized anyway (its text layer is destroyed
    /// with the rest), while a page with none is copied through as vector and keeps the matched text
    /// verbatim. The export gate uses this to tell the user which pages actually need rasterizing.
    public var unlocatablePages: [Int: Int] = [:]

    /// Total occurrences that couldn't be marked. Surfaced rather than dropped silently: a redaction
    /// tool must not hide a match it couldn't mark.
    var unlocatableMatches: Int { unlocatablePages.values.reduce(0, +) }

    /// Occurrences found (an occurrence spanning two lines still counts once).
    public var matchCount: Int { matches.count }
    /// Distinct pages carrying at least one match.
    public var pageCount: Int { Set(matches.map(\.pageIndex)).count }

    /// The auto-marks to hand to the editor — one `RedactionMark` per line rectangle, tagged so the
    /// UI can distinguish and clear them.
    public func marks() -> [RedactionMark] {
        matches.flatMap { match in
            match.rects.map { RedactionMark(pageIndex: match.pageIndex, rect: $0, origin: .autoMatch) }
        }
    }
}

extension PDFToolkit {
    /// Scans every page's text for `query` and returns the rectangles each match covers, in PDF user
    /// space — the exact coordinate space ``redactData(inputURL:marks:options:)`` fills, so the
    /// returned marks drop straight into the redaction pipeline.
    ///
    /// Call it on the caller's PDF serial queue (see the threading contract in `PDFToolkitCore.swift`):
    /// `PDFDocument` text extraction and selection geometry are not thread-safe, and this must not race
    /// a live document the caller is displaying.
    /// Per-page `progress` mirrors OCR so long documents can show a scan bar; `isCancelled` lets the
    /// caller abort a sweep that's outlived its screen.
    ///
    /// Geometry: for each match the character range is turned into a `PDFSelection`, split into per-
    /// line selections, and each line's `bounds(for:)` is taken — PDFKit returns those in the page's
    /// unrotated user space, matching what the redaction fill expects, so rotated and cropped pages
    /// need no hand-rolled coordinate math. Bounds are clipped to the crop box (the visible region)
    /// exactly as a manual ⇧-drag is.
    public static func findRedactionMarks(
        inputURL: URL,
        query: FindRedactQuery,
        progress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> FindRedactResult {
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let matcher = try TextMatcher(query: query)

        var matches: [FindRedactMatch] = []
        var pagesWithoutText: [Int] = []
        var unlocatable: [Int: Int] = [:]

        for pageIndex in 0..<source.pageCount {
            progress?(pageIndex + 1, source.pageCount)
            if isCancelled?() == true { throw CancellationError() }

            guard let page = source.page(at: pageIndex) else { continue }
            let text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pagesWithoutText.append(pageIndex)
                continue
            }

            let cropBox = page.bounds(for: .cropBox)
            for range in matcher.ranges(in: text) {
                let rects = Self.rects(forCharacterRange: range, on: page, cropBox: cropBox)
                if rects.isEmpty {
                    // Matched in the text layer but no on-page rectangle (no selection geometry, or the
                    // match clips wholly into a cropped-out margin) — can't place a box. Count it so the
                    // tool warns instead of silently under-marking a value it did find.
                    unlocatable[pageIndex, default: 0] += 1
                } else {
                    matches.append(FindRedactMatch(pageIndex: pageIndex, rects: rects))
                }
            }
        }

        return FindRedactResult(matches: matches, pagesWithoutText: pagesWithoutText, unlocatablePages: unlocatable)
    }

    /// A match's character range → the covering rectangle(s) in PDF user space, one per visual line.
    private static func rects(forCharacterRange range: NSRange, on page: PDFPage, cropBox: CGRect) -> [CGRect] {
        guard range.length > 0, let selection = page.selection(for: range) else { return [] }
        // `selectionsByLine` splits a wrapped match into one selection per line; a single-line match
        // (the common case) comes back as one, and an empty result means fall back to the whole thing.
        let lines = selection.selectionsByLine()
        let perLine = lines.isEmpty ? [selection] : lines

        var rects: [CGRect] = []
        for line in perLine {
            let bounds = line.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
            // A hair of outward padding guarantees ascenders/descenders and the last glyph edge are
            // fully covered — a redaction must never leave a sliver of the value peeking. Clipped to
            // the crop box just like a hand-drawn mark so it can't reach into a cropped-out margin.
            let padded = bounds.insetBy(dx: -1.5, dy: -1)
            if let clipped = RedactionMarkGeometry.clip(padded, to: cropBox) {
                rects.append(clipped)
            }
        }
        return rects
    }
}

/// Compiles a ``FindRedactQuery`` once, then finds every occurrence in a page's text. Built inside
/// the serial-queue closure and reused across pages, so a preset's regex is compiled a single time.
private struct TextMatcher {
    private enum Kind {
        case literal(String)
        /// A compiled preset regex plus its optional semantic filter (e.g. the card Luhn check), run
        /// against each hit in the match-collection step so a permissive shape doesn't over-mark.
        case regex(NSRegularExpression, accepts: (@Sendable (String) -> Bool)?)
    }
    private let kind: Kind

    init(query: FindRedactQuery) throws {
        switch query {
        case .literal(let raw):
            let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { throw PDFOperationError.noRedactions }
            kind = .literal(needle)
        case .pattern(let pattern):
            // The built-in patterns are valid; a compile failure would be a programmer error, mapped
            // to the same generic failure the redaction pipeline uses.
            guard let regex = try? NSRegularExpression(pattern: pattern.regexPattern, options: [.caseInsensitive]) else {
                throw PDFOperationError.redactionFailed
            }
            kind = .regex(regex, accepts: pattern.acceptsMatch)
        }
    }

    /// Every match range (UTF-16, indexing into `text` the way `PDFPage.selection(for:)` expects).
    func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        switch kind {
        case .literal(let needle):
            var found: [NSRange] = []
            var searchStart = 0
            while searchStart < ns.length {
                let scope = NSRange(location: searchStart, length: ns.length - searchStart)
                let r = ns.range(of: needle, options: [.caseInsensitive], range: scope)
                guard r.location != NSNotFound else { break }
                found.append(r)
                searchStart = r.location + max(r.length, 1)
            }
            return found
        case .regex(let regex, let accepts):
            let results = regex.matches(in: text, options: [], range: full)
            guard let accepts else { return results.map(\.range) }
            // Drop hits the semantic filter rejects (a digit run that fails the card Luhn check), so a
            // deliberately broad shape doesn't turn every long number into a mark.
            return results.compactMap { accepts(ns.substring(with: $0.range)) ? $0.range : nil }
        }
    }
}
