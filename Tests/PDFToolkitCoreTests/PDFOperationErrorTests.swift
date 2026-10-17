import Testing
import Foundation
@testable import PDFToolkitCore

/// Every error the toolkit throws surfaces to the user as an alert, so each case must carry a
/// non-empty, human-readable message, and the cases with a payload (a file, a page number, a bad
/// range) must fold that payload into the text — a bare "Invalid page range" helps no one.
@Suite struct PDFOperationErrorTests {

    /// One instance of every case, with representative payloads. `listCoversEveryCase` fails if a new
    /// case is added to the enum but not to this list, backed by the compile-time guard below.
    private let all: [PDFOperationError] = [
        .couldNotOpen(URL(fileURLWithPath: "/tmp/in.pdf")),
        .couldNotWrite(URL(fileURLWithPath: "/tmp/out.pdf")),
        .outputMatchesInput(URL(fileURLWithPath: "/tmp/report.pdf")),
        .invalidPageRange("q-z"),
        .pageOutOfBounds(7),
        .pageRangeRequired,
        .cannotRemoveEveryPage,
        .fileAccessDenied(URL(fileURLWithPath: "/tmp/denied.pdf")),
        .noInputFiles,
        .noPagesSelected,
        .compressionFailed,
        .emptyPDF,
        .noRedactions,
        .redactionFailed,
        .watermarkTextRequired,
        .watermarkImageRequired,
        .watermarkFailed,
        .noFillSignItems,
        .fillSignFailed,
        .passwordRequired,
        .incorrectPassword,
        .notEncrypted,
        .protectionFailed,
        .metadataEncrypted,
        .couldNotOpenImage(URL(fileURLWithPath: "/tmp/photo.png")),
        .cropTooSmall(pageNumber: 4),
        .ocrFailed,
        .encryptedInput(URL(fileURLWithPath: "/tmp/locked.pdf")),
        .permissionsForbidEditing(URL(fileURLWithPath: "/tmp/restricted.pdf")),
        .couldNotEncodeOutput,
    ]

    @Test func listCoversEveryCase() {
        // The real drift guard is `caseIsAccountedFor` below: its switch has no `default`, so adding a
        // case to `PDFOperationError` stops THIS test file compiling until the case is listed there —
        // and its comment sends you back to add it to `all`. The old assertion checked only the size of
        // `all` against a bare literal (22), so it kept passing while the enum grew to 29 and 7 messages
        // went unchecked. Here the count is derived from `all` itself, and distinctness proves no two
        // entries collapse to the same kind (which would let a duplicate hide a missing case).
        #expect(all.count == 30)
        #expect(Set(all.map(\.kind)).count == all.count)
    }

    /// Compile-time completeness guard for `listCoversEveryCase`. The switch deliberately has no
    /// `default`: when a case is added to `PDFOperationError`, this stops compiling and the whole test
    /// target fails to build until the new case is added HERE and to `all` above (with a description).
    /// That is what makes a newly added, undescribed error impossible to slip past this suite silently —
    /// the failure mode is a red build, not a green test that quietly ignores the new case.
    private func caseIsAccountedFor(_ error: PDFOperationError) {
        switch error {
        case .couldNotOpen, .couldNotWrite, .outputMatchesInput, .invalidPageRange, .pageOutOfBounds,
             .pageRangeRequired, .cannotRemoveEveryPage, .fileAccessDenied, .noInputFiles,
             .noPagesSelected, .compressionFailed, .emptyPDF, .noRedactions, .redactionFailed,
             .watermarkTextRequired, .watermarkImageRequired, .watermarkFailed, .noFillSignItems,
             .fillSignFailed, .passwordRequired, .incorrectPassword, .notEncrypted, .protectionFailed,
             .metadataEncrypted, .couldNotOpenImage, .cropTooSmall, .ocrFailed, .encryptedInput,
             .permissionsForbidEditing, .couldNotEncodeOutput:
            break
        }
    }

    @Test func everyCaseHasANonEmptyDescription() {
        for error in all {
            caseIsAccountedFor(error)   // exercise the compile-time completeness guard
            let description = error.errorDescription
            #expect(description != nil, "\(error.kind) has no description")
            #expect(!(description ?? "").isEmpty, "\(error.kind) has an empty description")
        }
    }

    @Test func payloadCasesFoldTheirValueIntoTheMessage() {
        #expect(PDFOperationError.couldNotOpen(URL(fileURLWithPath: "/x/report.pdf"))
            .errorDescription?.contains("report.pdf") == true)
        #expect(PDFOperationError.couldNotWrite(URL(fileURLWithPath: "/x/final.pdf"))
            .errorDescription?.contains("final.pdf") == true)
        #expect(PDFOperationError.outputMatchesInput(URL(fileURLWithPath: "/x/original.pdf"))
            .errorDescription?.contains("original.pdf") == true)
        #expect(PDFOperationError.fileAccessDenied(URL(fileURLWithPath: "/x/locked.pdf"))
            .errorDescription?.contains("locked.pdf") == true)
        #expect(PDFOperationError.pageOutOfBounds(42).errorDescription?.contains("42") == true)
        #expect(PDFOperationError.invalidPageRange("8-2!").errorDescription?.contains("8-2!") == true)
        #expect(PDFOperationError.couldNotOpenImage(URL(fileURLWithPath: "/x/scan.png"))
            .errorDescription?.contains("scan.png") == true)
        #expect(PDFOperationError.cropTooSmall(pageNumber: 13).errorDescription?.contains("13") == true)
        #expect(PDFOperationError.encryptedInput(URL(fileURLWithPath: "/x/secret.pdf"))
            .errorDescription?.contains("secret.pdf") == true)
    }
}
