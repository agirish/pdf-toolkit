import Foundation
import PDFKit

/// What a tool's output will genuinely lose, detected from the loaded source file(s).
///
/// Three limits can't be engineered away, so they are disclosed instead of discovered. All were
/// confirmed empirically against a hand-authored PDF carrying a real catalog `/AcroForm`
/// (PDFKit's writer won't produce one from widget annotations, so the fixture is assembled byte by
/// byte — see `PDFFixtures.writeAcroFormPDF`):
///
/// - **A form is flattened** by the tools that re-emit each page through a `CGPDFContext`
///   (Watermark, OCR, Fill & Sign, Compress, Redact). Both the catalog `/AcroForm` AND the widget
///   annotations go: the field's *appearance* is painted into the page, so the saved copy looks and
///   prints identically, but nothing interactive remains.
/// - **A form is orphaned** by the tools that rebuild by copying pages into a fresh document
///   (Extract, Reorder, Crop, Merge, Split). The widget annotations ride along on the copied pages,
///   but the catalog `/AcroForm` that binds them into a form does not — so the fields stay visible
///   and keep their values, yet no reader treats them as a fillable form any more. This is the
///   subtler of the two, which is exactly why it needs saying.
/// - **Bookmarks are dropped** by Merge and Split. A merge concatenates outlines from many documents
///   at shifting page offsets; a split cuts one outline across several files. Both deliberately drop
///   rather than ship misdirected bookmarks (see the NOTE comments in `PDFToolkit.mergeData` /
///   `PDFToolkit.split`).
///
/// Delete and Rotate mutate the document in place and lose none of the three.
///
/// A warning is only ever built when the *loaded file actually has* the thing at risk, so it stays
/// meaningful rather than becoming permanent wallpaper. Everything else these rebuilds used to lose —
/// bookmarks outside merge/split, the document title, links — is now preserved, so it is
/// deliberately not listed here.
public struct OutputFidelityWarning: Equatable, Sendable {
    /// One thing this tool's output will lose. A tool can have more than one — Merge and Split lose
    /// both a form and bookmarks.
    public enum Loss: Equatable, Sendable {
        /// Catalog form and widgets both gone; the fields' appearance is baked into the page.
        case formFlattened
        /// Widgets survive as visible annotations, but the catalog `/AcroForm` does not.
        case formOrphaned
        /// `total` bookmarks across `fileCount` source files.
        case bookmarks(total: Int, fileCount: Int)

        var isFormLoss: Bool {
            switch self {
            case .formFlattened, .formOrphaned: return true
            case .bookmarks: return false
            }
        }
    }

    /// In detection order, so the banner reads the same way every time.
    public var losses: [Loss]

    /// The memberwise initializer, spelled out so it can be public.
    public init(losses: [Loss]) {
        self.losses = losses
    }

    private var losesForm: Bool { losses.contains(where: \.isFormLoss) }
    private var losesBookmarks: Bool { losses.contains { !$0.isFormLoss } }

    public var symbolName: String {
        losesForm ? "exclamationmark.triangle.fill" : "bookmark.slash.fill"
    }

    public var headline: String {
        guard losses.count == 1 else { return "Some things won’t carry over" }
        switch losses[0] {
        case .formFlattened, .formOrphaned: return "This PDF has fillable form fields"
        case .bookmarks: return "Bookmarks won’t carry over"
        }
    }

    /// One sentence per loss, each stating exactly what goes.
    public func detailLines(toolTitle: String) -> [String] {
        losses.map { loss in
            switch loss {
            case .formFlattened:
                return "The form fields will be flattened into the page — the saved copy looks identical but can no longer be filled in or edited."
            case .formOrphaned:
                return "The form fields will stop working — they stay visible, and keep any values already filled in, but no reader will treat them as a fillable form again."
            case .bookmarks(let total, let fileCount):
                let bookmarks = total == 1 ? "1 bookmark" : "\(total) bookmarks"
                let source = fileCount <= 1
                    ? "This PDF has \(bookmarks)"
                    : "\(fileCount) of these files have bookmarks (\(bookmarks) in total)"
                return "\(source), and the \(toolTitle.lowercased()) output won’t have any."
            }
        }
    }

    /// The "and here's what survives" clause, so the warning never reads as "this tool ruins your
    /// file". Tailored to which losses actually apply.
    public var keptLine: String {
        switch (losesForm, losesBookmarks) {
        case (true, true): return "Page content, links, and the document title are kept."
        case (true, false): return "Bookmarks, links, and the document title are kept."
        case (false, true): return "Page content, links, form fields, and the document title are kept."
        case (false, false): return ""
        }
    }

    /// The whole thing as one string — the confirmation's message, and the accessibility label.
    public func detail(toolTitle: String) -> String {
        (detailLines(toolTitle: toolTitle) + [keptLine])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var confirmationTitle: String {
        guard losses.count == 1 else { return "Some things won’t carry over" }
        switch losses[0] {
        case .formFlattened: return "Form fields will be flattened"
        case .formOrphaned: return "Form fields will stop working"
        case .bookmarks: return "Bookmarks won’t carry over"
        }
    }

    public var confirmButtonTitle: String {
        guard losses.count == 1 else { return "Continue anyway" }
        switch losses[0] {
        case .formFlattened: return "Flatten and continue"
        case .formOrphaned: return "Continue anyway"
        case .bookmarks: return "Continue without bookmarks"
        }
    }

    // MARK: Detection

    /// Builds the warning for `urls`, or nil when none of the requested checks finds anything at risk.
    ///
    /// `formLoss` is how THIS tool damages a form (nil = it doesn't); `checksBookmarks` is whether
    /// this tool drops them. Both are properties of the tool; whether they *matter* is a property of
    /// the loaded file — which is what makes the warning conditional.
    ///
    /// Opens PDFs, so call it off the main actor, on the caller's PDF serial queue.
    public static func detect(in urls: [URL], formLoss: Loss?, checksBookmarks: Bool) -> OutputFidelityWarning? {
        var losses: [Loss] = []
        if let formLoss, urls.contains(where: hasForm(at:)) {
            losses.append(formLoss)
        }
        if checksBookmarks, let bookmarks = bookmarkLoss(in: urls) {
            losses.append(bookmarks)
        }
        return losses.isEmpty ? nil : OutputFidelityWarning(losses: losses)
    }

    private static func hasForm(at url: URL) -> Bool {
        (try? url.withSecurityScopedAccess { PDFToolkit.hasInteractiveForm(at: url) }) ?? false
    }

    private static func bookmarkLoss(in urls: [URL]) -> Loss? {
        var total = 0
        var files = 0
        for url in urls {
            let count = (try? url.withSecurityScopedAccess { PDFToolkit.bookmarkCount(at: url) }) ?? 0
            if count > 0 {
                total += count
                files += 1
            }
        }
        return total > 0 ? .bookmarks(total: total, fileCount: files) : nil
    }
}
