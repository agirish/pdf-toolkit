import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// The committed corpus of real PDF files, and the traits each one is kept for.
///
/// Everything else in this suite builds its fixtures at run time out of a
/// `CGPDFContext`. That is the right default — it keeps tests self-describing and
/// lets a test state exactly the shape it needs — but it means every input the
/// suite has ever seen was written by one producer, in one style: a plain
/// cross-reference table, no object streams, no embedded font programs, no
/// catalog `/AcroForm` (PDFKit's writer will not emit one), no encryption
/// dictionary the app didn't write itself.
///
/// The corpus covers that gap with a deliberately small set of files a user could
/// plausibly drop on the app, each carrying one corner case the tools warn about
/// or have historically got wrong. They are checked in rather than generated
/// during `swift test`: CI must not depend on Chrome being installed, and a
/// fixture regenerated on every run can drift underneath the assertions. Regenerate
/// with `scripts/corpus/generate.sh`; the shapes are documented in
/// `docs/testing-corpus.md`.
///
/// None of these files contains real personal data. Every identifier in them —
/// names, card numbers, emails — is invented for the redaction tests.
enum RealCorpus: String, CaseIterable {
    /// Chrome/Skia-produced, 3 pages. Embedded subset font programs and real link
    /// annotations (internal, external, mailto) — neither of which Apple's writer
    /// emits. The suite's only input from a foreign producer.
    case chromeArticle = "chrome-article.pdf"

    /// A genuine catalog `/AcroForm` (text field + checkbox, both with appearance
    /// streams) inside a PDF 1.6 *object stream* behind a cross-reference *stream*,
    /// plus an XMP `/Metadata` packet and a full Info dictionary. The only corpus
    /// file whose objects must be inflated before the catalog is even visible.
    case acroFormXrefStream = "acroform-xrefstream.pdf"

    /// 6 pages under a NESTED outline — 3 top-level entries, one with 3 children —
    /// plus a document title and an internal link. Merge and Split warn about
    /// bookmarks; Delete/Extract/Reorder must re-point the survivors.
    case outlineNested = "outline-nested.pdf"

    /// 4 pages at 3 different sizes, each at a different `/Rotate`, every crop box
    /// smaller than its media box AND at a non-zero origin. Origin-zero fixtures
    /// have hidden shipped geometry bugs before, so nothing here is at the origin.
    case rotatedCropped = "rotated-cropped.pdf"

    /// 2 image-only pages: a JPEG of printed text with no text layer behind it.
    /// The only corpus file that makes OCR do real work and the only one Compress
    /// can genuinely shrink.
    case scannedReceipt = "scanned-receipt.pdf"

    /// Encrypted with a user password (``userPassword``): PDFKit reports `isLocked`
    /// and nothing can be read until it is unlocked.
    case encryptedUser = "encrypted-user.pdf"

    /// Encrypted with an owner password only: it opens with no prompt and is NOT
    /// `isLocked`, yet page assembly is denied. The shape that once let Rotate and
    /// Delete silently no-op and still report success.
    case ownerRestricted = "owner-restricted.pdf"

    /// The password `encryptedUser` is locked with.
    static let userPassword = "open-sesame"

    var url: URL {
        // `Bundle.module` is SwiftPM-only, which is why the corpus is reachable
        // from the package test target and not from the app target.
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: nil, subdirectory: "Corpus") else {
            fatalError("Corpus file \(rawValue) is missing — run scripts/corpus/generate.sh")
        }
        return url
    }

    /// A working copy in `dir`, so a test can hand a tool a writable path and never
    /// risk mutating the bundled resource itself.
    @discardableResult
    func copy(into dir: FixtureDir, as name: String? = nil) throws -> URL {
        let dest = dir.url(name ?? rawValue)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    var data: Data { get throws { try Data(contentsOf: url) } }

    /// Opens the file, unlocking it first when it is the user-password one.
    func document() throws -> PDFDocument {
        let doc = try #require(PDFDocument(url: url))
        if doc.isLocked { #expect(doc.unlock(withPassword: Self.userPassword)) }
        return doc
    }

    // MARK: What each file is guaranteed to be

    /// The traits the rest of the suite relies on. Asserted wholesale by
    /// ``RealCorpusIntegrityTests``, so a regenerated or truncated file fails once,
    /// loudly, instead of as a scatter of confusing downstream failures.
    struct Traits {
        var pageCount: Int
        var isLocked = false
        var isEncrypted = false
        /// Checked AFTER unlocking, which is the state the operations see. A
        /// user-password file grants full access once the password is supplied;
        /// only an owner-restricted one still refuses assembly at that point.
        var allowsAssembly = true
        var hasForm = false
        var bookmarkCount = 0
        /// A token drawn on page 1 that must survive round-trips — or nil where the
        /// page has no text layer at all.
        var firstPageToken: String?
    }

    var traits: Traits {
        switch self {
        case .chromeArticle:
            return Traits(pageCount: 3, firstPageToken: "CORPUSTOKEN-ALPHA")
        case .acroFormXrefStream:
            return Traits(pageCount: 2, hasForm: true, firstPageToken: "CORPUSTOKEN-FORM")
        case .outlineNested:
            return Traits(pageCount: 6, bookmarkCount: 6, firstPageToken: "CORPUSTOKEN-OUTLINE")
        case .rotatedCropped:
            return Traits(pageCount: 4, firstPageToken: "CORPUSTOKEN-GEOM")
        case .scannedReceipt:
            return Traits(pageCount: 2, firstPageToken: nil)
        case .encryptedUser:
            return Traits(pageCount: 3, isLocked: true, isEncrypted: true,
                          firstPageToken: "CORPUSTOKEN-SECURE")
        case .ownerRestricted:
            return Traits(pageCount: 3, isEncrypted: true, allowsAssembly: false,
                          firstPageToken: "CORPUSTOKEN-SECURE")
        }
    }
}
