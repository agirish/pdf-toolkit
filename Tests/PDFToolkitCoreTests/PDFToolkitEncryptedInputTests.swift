import Testing
import Foundation
import PDFKit
@testable import PDFToolkitCore

/// Every content operation must refuse a password-locked input up front.
///
/// A locked `PDFDocument` opens without error and reports its real page count, but its pages are
/// placeholders: copying them produced blank US-Letter pages, so merge/extract/split/reorder
/// silently wrote contentless output and recorded it as a successful save — the worst failure mode
/// a PDF utility can have. These tests pin the guard on each read path, and one test documents the
/// underlying PDFKit behavior the guard exists for, so a future "is this still needed?" question
/// has its answer next to the code.
@Suite struct PDFToolkitEncryptedInputTests {

    /// A two-page marker PDF locked with "secret", plus its plain sibling.
    private func makeLocked(_ dir: FixtureDir) throws -> (plain: URL, locked: URL) {
        let plain = dir.url("plain.pdf"), locked = dir.url("locked.pdf")
        try PDFFixtures.writePDF(pageCount: 2, to: plain)
        try PDFToolkit.encrypt(inputURL: plain, outputURL: locked, password: "secret")
        return (plain, locked)
    }

    private func expectEncryptedInput(_ body: () throws -> Void) {
        #expect(#expect(throws: PDFOperationError.self) { try body() }?.kind == "encryptedInput")
    }

    // MARK: The silent-blank-pages paths (page.copy())

    @Test func mergeRefusesALockedInputInsteadOfEmittingBlankPages() throws {
        let dir = FixtureDir()
        let (plain, locked) = try makeLocked(dir)
        let out = dir.url("out.pdf")
        expectEncryptedInput {
            try PDFToolkit.merge(inputURLs: [plain, locked], outputURL: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func extractRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            try PDFToolkit.extract(inputURL: locked, outputURL: dir.url("out.pdf"), pageIndices: [0])
        }
    }

    @Test func splitRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            _ = try PDFToolkit.split(inputURL: locked, into: dir.url, baseName: "part", segments: [[0], [1]])
        }
    }

    @Test func reorderRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            try PDFToolkit.reorder(inputURL: locked, outputURL: dir.url("out.pdf"), order: [1, 0])
        }
    }

    // MARK: The misleading-error paths (write-back / pageRef)

    @Test func deletePagesRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            try PDFToolkit.deletePages(inputURL: locked, outputURL: dir.url("out.pdf"), pageIndices: [0])
        }
    }

    @Test func rotateRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            try PDFToolkit.rotate(inputURL: locked, outputURL: dir.url("out.pdf"), pageIndices: [0], quarterTurns: 1)
        }
    }

    @Test func compressRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            try PDFToolkit.compress(inputURL: locked, outputURL: dir.url("out.pdf"), quality: 0.6)
        }
    }

    @Test func compressToTargetRefusesALockedInputEvenWhenItAlreadyFits() throws {
        // The guard must sit before the pass-through: a locked file under the target used to be
        // copied byte-for-byte under a "-compressed" name, which reads as a successful compression.
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            try PDFToolkit.compressToTarget(inputURL: locked, outputURL: dir.url("out.pdf"), targetBytes: .max)
        }
    }

    @Test func watermarkRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        let options = WatermarkOptions(
            text: "DRAFT", fontSize: 48, opacity: 0.3, rotationDegrees: 45,
            red: 1, green: 0, blue: 0, tiled: false
        )
        expectEncryptedInput {
            try PDFToolkit.watermark(inputURL: locked, outputURL: dir.url("out.pdf"), options: options)
        }
    }

    @Test func fillAndSignRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        let item = FillSignItem(
            pageIndex: 0,
            rect: CGRect(x: 100, y: 100, width: 200, height: 40),
            content: .text(FillSignText(string: "Name", fontSize: 14, red: 0, green: 0, blue: 0, isScript: false))
        )
        expectEncryptedInput {
            try PDFToolkit.fillAndSign(inputURL: locked, outputURL: dir.url("out.pdf"), items: [item])
        }
    }

    @Test func redactRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 50, y: 50, width: 100, height: 20))
        expectEncryptedInput {
            try PDFToolkit.redact(inputURL: locked, outputURL: dir.url("out.pdf"), marks: [mark])
        }
    }

    @Test func cropRefusesALockedInput() throws {
        // Crop copies pages (`page.copy()`) — the silent-blank-pages failure mode.
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            try PDFToolkit.crop(
                inputURL: locked, outputURL: dir.url("out.pdf"),
                insets: CropInsets(top: 10, left: 10, bottom: 10, right: 10)
            )
        }
    }

    @Test func autoCropRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            try PDFToolkit.autoCrop(inputURL: locked, outputURL: dir.url("out.pdf"), padding: 8, unified: false)
        }
    }

    @Test func ocrRefusesALockedInput() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        expectEncryptedInput {
            _ = try PDFToolkit.ocr(inputURL: locked, outputURL: dir.url("out.pdf"), options: OCROptions())
        }
    }

    // MARK: Paths that must keep working

    @Test func removePasswordStillUnlocksALockedInput() throws {
        // The one operation whose whole job is locked input — the guard must not reach it.
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        let out = dir.url("out.pdf")
        try PDFToolkit.removePassword(inputURL: locked, outputURL: out, password: "secret")
        let reopened = try #require(PDFDocument(url: out))
        #expect(!reopened.isLocked)
        #expect(reopened.pageCount == 2)
    }

    @Test func ownerRestrictedButUnlockedPDFsStillWorkEverywhere() throws {
        // The guard must key on isLocked, NOT isEncrypted: an owner-password-only PDF (the shape
        // of third-party "restrictions-only" files) opens without a prompt and its pages are fully
        // real. Before this fixture existed, "tightening" the guard to isEncrypted would have kept
        // all tests green while every operation started refusing such files — the review called
        // this the best silent-regression window in the guard's design.
        let dir = FixtureDir()
        let restricted = dir.url("restricted.pdf")
        try PDFFixtures.writeOwnerRestrictedPDF(markers: ["MARKERPAGE1", "MARKERPAGE2"], to: restricted)

        let doc = try #require(PDFDocument(url: restricted))
        #expect(doc.isEncrypted)      // precondition: the fixture really is encrypted…
        #expect(!doc.isLocked)        // …but not locked — PDFKit opens it implicitly

        // A copy path (the silent-blank-pages family) must produce REAL content, not placeholders.
        let extracted = dir.url("extracted.pdf")
        try PDFToolkit.extract(inputURL: restricted, outputURL: extracted, pageIndices: [1])
        #expect(try PDFFixtures.pageTexts(at: extracted) == ["MARKERPAGE2"])

        // And a rasterizing path must pass the guard too.
        try PDFToolkit.compress(inputURL: restricted, outputURL: dir.url("compressed.pdf"), quality: 0.5)
    }

    /// Documents WHY the guard exists: pages copied out of a locked document are blank
    /// placeholders, not the real content. If PDFKit ever starts refusing the copy instead,
    /// this test will flag that the guard's rationale (though not the guard) is stale.
    @Test func lockedPagesCopyAsBlankPlaceholders() throws {
        let dir = FixtureDir()
        let (_, locked) = try makeLocked(dir)
        let doc = try #require(PDFDocument(url: locked))
        #expect(doc.isLocked)
        #expect(doc.pageCount == 2) // the trap: the count looks perfectly normal
        let copy = try #require(doc.page(at: 0)?.copy() as? PDFPage)
        #expect(copy.string?.isEmpty != false) // the content is gone
    }
}
