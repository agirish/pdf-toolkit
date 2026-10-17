import Foundation
import PDFKit
import Testing
@testable import PDFToolkitCore

/// A PDF encrypted with an OWNER password only opens freely and is not `isLocked`, but PDFKit
/// silently refuses to mutate it: `page.rotation = …` and `removePage(at:)` become no-ops that log
/// to the console and nothing else, while `dataRepresentation()` still succeeds. Rotate and Delete
/// therefore used to "succeed" and land an UNCHANGED file under a `-rotated` / `-deleted` name —
/// for Delete, a page the user believed was gone shipping inside the output.
///
/// This shape is common in the wild (statements, corporate reports) and is exactly what this app's
/// own Protect ▸ "Restrict editing" mode writes, so it is reachable end-to-end from the app.
struct PDFToolkitRestrictedPermissionsTests {
    /// A 3-page PDF encrypted owner-password-only: opens with no password, forbids assembly.
    private func restrictedPDF(in dir: FixtureDir) throws -> URL {
        let plain = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: plain)
        let url = dir.url("restricted.pdf")
        try PDFToolkit.encryptData(
            inputURL: plain,
            options: .addPassword(restrictEditing: true, password: "owner")
        ).write(to: url)
        return url
    }

    @Test func fixtureOpensFreelyButForbidsAssembly() throws {
        let dir = FixtureDir()
        let doc = try #require(PDFDocument(url: try restrictedPDF(in: dir)))
        #expect(doc.isLocked == false)          // so `openUnlockedDocument` lets it through
        #expect(doc.isEncrypted)
        #expect(doc.allowsDocumentAssembly == false)
    }

    @Test func rotateRefusesRatherThanSavingAnUnrotatedFile() throws {
        let dir = FixtureDir()
        let url = try restrictedPDF(in: dir)
        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.rotateData(inputURL: url, pageIndices: [0, 1, 2], quarterTurns: 1)
        }
    }

    @Test func deleteRefusesRatherThanSavingTheDeletedPage() throws {
        let dir = FixtureDir()
        let url = try restrictedPDF(in: dir)
        #expect(throws: PDFOperationError.self) {
            try PDFToolkit.deletePagesData(inputURL: url, pageIndices: [1])
        }
    }

    /// The guard must be surgical: every rebuild-by-copy operation produced correct output on a
    /// restricted input before this change and must keep doing so.
    @Test func rebuildingOperationsStillWorkOnARestrictedInput() throws {
        let dir = FixtureDir()
        let url = try restrictedPDF(in: dir)

        let extracted = try #require(PDFDocument(data: try PDFToolkit.extractData(inputURL: url, pageIndices: [2, 0])))
        #expect(extracted.pageCount == 2)
        #expect(extracted.page(at: 0)?.string?.contains(PDFFixtures.marker(3)) == true)

        let merged = try #require(PDFDocument(data: try PDFToolkit.mergeData(inputURLs: [url, url])))
        #expect(merged.pageCount == 6)

        let cropped = try #require(PDFDocument(data: try PDFToolkit.cropData(
            inputURL: url, insets: CropInsets(top: 20, left: 20, bottom: 20, right: 20)
        )))
        #expect(cropped.pageCount == 3)

        let redacted = try #require(PDFDocument(data: try PDFToolkit.redactData(
            inputURL: url,
            marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 60, y: 380, width: 300, height: 50))]
        )))
        #expect(redacted.pageCount == 3)
    }

    /// An ordinary unencrypted document must be unaffected by the permission guard.
    @Test func plainDocumentsRotateAndDeleteNormally() throws {
        let dir = FixtureDir()
        let url = dir.url("plain.pdf")
        try PDFFixtures.writePDF(pageCount: 3, to: url)

        let rotated = try #require(PDFDocument(data: try PDFToolkit.rotateData(
            inputURL: url, pageIndices: [0, 2], quarterTurns: 1
        )))
        #expect(rotated.page(at: 0)?.rotation == 90)
        #expect(rotated.page(at: 1)?.rotation == 0)
        #expect(rotated.page(at: 2)?.rotation == 90)

        let deleted = try #require(PDFDocument(data: try PDFToolkit.deletePagesData(
            inputURL: url, pageIndices: [1]
        )))
        #expect(deleted.pageCount == 2)
        #expect(deleted.page(at: 1)?.string?.contains(PDFFixtures.marker(3)) == true)
    }
}
