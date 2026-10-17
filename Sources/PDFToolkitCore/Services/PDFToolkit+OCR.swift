import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

/// How recognition runs. Plain values so the options cross the PDF serial queue.
public struct OCROptions: Sendable {
    /// Accurate uses the slower neural path with language correction; Fast trades some hit rate
    /// for speed on long documents.
    var accurate = true
    /// Pages that already extract text are copied through untouched — running OCR over live vector
    /// text would stack a second, slightly-off text layer under every selection.
    var skipPagesWithText = true
    /// BCP-47 languages to recognize, most-preferred first. Empty means auto-detect (the default) —
    /// Vision picks per page. Naming a language guides recognition on documents Vision would otherwise
    /// misread (e.g. a language that shares an alphabet with another it detects first).
    var recognitionLanguages: [String] = []

    /// The memberwise initializer, spelled out so it can be public.
    public init(accurate: Bool = true, skipPagesWithText: Bool = true, recognitionLanguages: [String] = []) {
        self.accurate = accurate
        self.skipPagesWithText = skipPagesWithText
        self.recognitionLanguages = recognitionLanguages
    }
}

/// What an OCR run did, for the caller's messaging.
public struct OCRRunSummary: Sendable {
    public var recognizedPages = 0
    public var skippedPages = 0
}

extension PDFToolkit {
    /// Long-edge render sizes for recognition: ~300 dpi on US Letter for the accurate recognizer,
    /// half that for Fast — the mode users pick for speed shouldn't pay full rasterization cost.
    private static let accurateOCRPixelDimension: CGFloat = 3300
    private static let fastOCRPixelDimension: CGFloat = 1650

    /// One recognized line: the text and its normalized (0…1, lower-left origin) image rectangle.
    private typealias RecognizedLine = (string: String, normalizedRect: CGRect)

    /// Lays an invisible, selectable text layer behind every scanned page and writes a new PDF.
    static func ocr(
        inputURL: URL,
        outputURL: URL,
        options: OCROptions,
        progress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> OCRRunSummary {
        try requireDistinctOutput(outputURL, from: [inputURL])
        let (data, summary) = try ocrData(
            inputURL: inputURL, options: options, progress: progress, isCancelled: isCancelled
        )
        try writeOutput(data, to: outputURL)
        return summary
    }

    /// In-memory core of ``ocr(inputURL:outputURL:options:progress:isCancelled:)`` — returns the
    /// rebuilt PDF's bytes alongside the run summary the caller reports.
    ///
    /// Pages are rebuilt the way ``watermark`` rebuilds them — original content re-drawn as vector
    /// through `drawPDFPage` (nothing is rasterized), visible annotations flattened in, intrinsic
    /// rotation baked into an upright page. On pages with no extractable text, the page is rendered
    /// to a bitmap, Apple's Vision text recognition runs over it on-device, and each recognized
    /// line is drawn back in invisible text mode at its detected position, sized so selection
    /// highlights match the printed words underneath.
    public static func ocrData(
        inputURL: URL,
        options: OCROptions,
        progress: (@Sendable (_ page: Int, _ total: Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> (Data, OCRRunSummary) {
        let source = try openUnlockedDocument(at: inputURL)
        guard source.pageCount > 0 else { throw PDFOperationError.emptyPDF }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw PDFOperationError.ocrFailed
        }

        var summary = OCRRunSummary()
        for i in 0..<source.pageCount {
            progress?(i + 1, source.pageCount)
            if isCancelled?() == true { throw CancellationError() }
            // Per-page pool: the recognition bitmap (up to 3300 px on the long edge, tens of MB)
            // and Vision's scratch must drain per page, not pile up for the whole document.
            try autoreleasepool {
                let dp = try displayedPage(source.page(at: i), inputURL: inputURL)

                let needsRecognition: Bool
                if options.skipPagesWithText {
                    let existing = (dp.page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    needsRecognition = existing.isEmpty
                } else {
                    needsRecognition = true
                }

                var lines: [RecognizedLine] = []
                if needsRecognition {
                    let renderSize = options.accurate ? accurateOCRPixelDimension : fastOCRPixelDimension
                    guard let bitmap = renderPageBitmap(dp.page, maxPixelDimension: renderSize) else {
                        throw PDFOperationError.ocrFailed
                    }
                    lines = try recognizeText(in: bitmap, accurate: options.accurate, languages: options.recognitionLanguages)
                    summary.recognizedPages += 1
                } else {
                    summary.skippedPages += 1
                }

                emitDisplayedPage(dp, into: ctx) { ctx, dp in
                    for line in lines {
                        drawInvisibleLine(line.string, at: pageRect(for: line.normalizedRect, in: dp.box), in: ctx)
                    }
                }
            }
        }
        ctx.closePDF()

        guard pdfData.length > 0 else { throw PDFOperationError.ocrFailed }
        // Recognizing a long scanned book must not cost the reader its bookmarks, title, or links —
        // the CGPDFContext emits pages only, so the catalog is carried across explicitly.
        return (restoringCatalog(pdfData as Data, from: source, restoreLinks: true), summary)
    }

    /// The BCP-47 languages Vision can recognize on this Mac at the given accuracy level, most-preferred
    /// first as Vision reports them. Empty if the query fails. The tool populates its language menu from
    /// this **per level**: Fast supports far fewer languages than Accurate (e.g. no CJK/Cyrillic), and a
    /// language outside the running level's set is silently ignored (zero results) — so the menu must
    /// match the chosen level, not always Accurate.
    public static func supportedOCRLanguages(accurate: Bool = true) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        // The instance query reports the list for this request's own level and revision — exactly
        // what recognition will use — so no revision constant is hard-coded.
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    // MARK: Recognition

    /// Runs Vision over one page bitmap and returns per-line text with normalized rectangles.
    /// An empty `languages` list leaves Vision to auto-detect per page; a non-empty one pins the
    /// recognition languages (auto-detect off) so a document Vision would misread is read as chosen.
    private static func recognizeText(in image: CGImage, accurate: Bool, languages: [String]) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            // Vision ignores `recognitionLanguages` while auto-detect is on, so turn it off here.
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw PDFOperationError.ocrFailed
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return (candidate.string, observation.boundingBox)
        }
    }

    /// Vision's normalized lower-left-origin rectangle → displayed-page points. The recognition
    /// bitmap was rendered from the displayed page (rotation and crop applied), so normalized
    /// coordinates map straight onto the emitted page box.
    private static func pageRect(for normalized: CGRect, in box: CGRect) -> CGRect {
        CGRect(
            x: box.minX + normalized.minX * box.width,
            y: box.minY + normalized.minY * box.height,
            width: normalized.width * box.width,
            height: normalized.height * box.height
        )
    }

    /// Draws one line of text in invisible mode (PDF text-rendering mode 3), sized to the detected
    /// rectangle in BOTH dimensions: the font is fit to the rect's height (so selection highlights
    /// stay on this line instead of towering over it when Vision's box is wide relative to the
    /// glyph run — letter-spaced headings), then the glyph run is stretched horizontally via the
    /// text matrix to span the rect's width. The text is real vector text: searchable, selectable,
    /// copyable.
    private static func drawInvisibleLine(_ string: String, at rect: CGRect, in ctx: CGContext) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }

        let probeSize: CGFloat = 12
        let probeLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: probeSize)])
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let probeWidth = CGFloat(CTLineGetTypographicBounds(probeLine, &ascent, &descent, &leading))
        guard probeWidth > 0, ascent + descent > 0 else { return }

        let heightScale = rect.height / (ascent + descent)
        let fontSize = probeSize * heightScale
        let naturalWidth = probeWidth * heightScale
        let stretch = naturalWidth > 0 ? rect.width / naturalWidth : 1
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        )

        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        // Scale first: textPosition writes only the matrix's translation, so the stretch survives.
        ctx.textMatrix = CGAffineTransform(scaleX: stretch, y: 1)
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent * heightScale)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
