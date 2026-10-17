#!/usr/bin/env swift
//
// Renders the corpus PDFs that need a real drawing engine or a real encryptor.
//
// These four go through Quartz/PDFKit rather than being byte-authored, because
// what they must be real about is *content*, not file structure: genuine glyph
// runs from an embedded font, a genuine JPEG image with no text layer behind it,
// genuine RC4/AES encryption dictionaries. Their structural counterparts are in
// make_structural.py; the browser-produced one comes from generate.sh.
//
// Usage: swift scripts/corpus/make_rendered.swift <output-dir>

import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func report(_ url: URL) {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
    print("\(url.lastPathComponent): \(size) bytes")
}

/// Draws `lines` as real text, top-down from `startY`, at `size` points.
func draw(_ lines: [String], in ctx: CGContext, startY: CGFloat, size: CGFloat, x: CGFloat = 72) {
    var y = startY
    for line in lines {
        let attributed = NSAttributedString(
            string: line,
            attributes: [.font: NSFont.systemFont(ofSize: size)]
        )
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        y -= size * 1.6
    }
}

func pdfContext(_ url: URL, options: [CFString: Any] = [:]) -> CGContext {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    return CGContext(url as CFURL, mediaBox: &box, options as CFDictionary)!
}

// MARK: - outline-nested.pdf
//
// A six-page handbook with a NESTED outline (three top-level entries, two of
// them with children) plus an internal link. Merge and Split warn that bookmarks
// won't carry over, and Delete/Extract/Reorder must re-point the survivors — a
// flat one-per-page outline can't distinguish "kept the tree" from "kept a list",
// so the tree is the fixture.

do {
    let base = outDir.appendingPathComponent("outline-base.pdf")
    let ctx = pdfContext(base)
    let chapters = [
        ("Front Matter", ["CORPUSTOKEN-OUTLINE page 1", "Northbridge Field Handbook", "Revision 7"]),
        ("Contents", ["CORPUSTOKEN-OUTLINE page 2", "1. Siting", "2. Power", "3. Uplink"]),
        ("Siting", ["CORPUSTOKEN-OUTLINE page 3", "Choose level ground clear of runoff.",
                    "Sensitive: contact Dana Reyes, badge 4417-9920."]),
        ("Power", ["CORPUSTOKEN-OUTLINE page 4", "Battery bank sizing and cell drift."]),
        ("Uplink", ["CORPUSTOKEN-OUTLINE page 5", "Antenna alignment and link budget."]),
        ("Index", ["CORPUSTOKEN-OUTLINE page 6", "siting 3, power 4, uplink 5"]),
    ]
    for (title, lines) in chapters {
        ctx.beginPDFPage(nil)
        draw([title], in: ctx, startY: 700, size: 22)
        draw(lines, in: ctx, startY: 640, size: 13)
        ctx.endPDFPage()
    }
    ctx.closePDF()

    let doc = PDFDocument(url: base)!
    doc.documentAttributes = [
        PDFDocumentAttribute.titleAttribute: "Northbridge Field Handbook",
        PDFDocumentAttribute.authorAttribute: "CORPUS-INFO-AUTHOR",
        PDFDocumentAttribute.subjectAttribute: "Nested-outline corpus fixture",
    ]
    func node(_ label: String, _ page: Int) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = label
        outline.destination = PDFDestination(page: doc.page(at: page)!, at: CGPoint(x: 0, y: 792))
        return outline
    }
    let root = PDFOutline()
    root.insertChild(node("Front Matter", 0), at: 0)
    let contents = node("Contents", 1)
    contents.insertChild(node("Siting", 2), at: 0)
    contents.insertChild(node("Power", 3), at: 1)
    contents.insertChild(node("Uplink", 4), at: 2)
    root.insertChild(contents, at: 1)
    root.insertChild(node("Index", 5), at: 2)
    doc.outlineRoot = root

    // An internal link on page 1 aimed at page 3, so link preservation is
    // observable independently of the outline.
    let link = PDFAnnotation(
        bounds: CGRect(x: 72, y: 600, width: 200, height: 20),
        forType: .link,
        withProperties: nil
    )
    link.action = PDFActionGoTo(destination: PDFDestination(page: doc.page(at: 2)!, at: CGPoint(x: 0, y: 700)))
    doc.page(at: 0)!.addAnnotation(link)

    let out = outDir.appendingPathComponent("outline-nested.pdf")
    doc.write(to: out)
    try? FileManager.default.removeItem(at: base)
    report(out)
}

// MARK: - rotated-cropped.pdf
//
// The geometry torture page-set: four pages of THREE different sizes, each at a
// different /Rotate, and every CropBox both smaller than its MediaBox and at a
// NON-ZERO ORIGIN. Origin-zero fixtures previously hid three shipped bugs, so
// every box here is deliberately offset. Each page prints its own dimensions so
// a failure names itself.

do {
    let base = outDir.appendingPathComponent("rot-base.pdf")
    // page: (media size, crop inset origin, crop size, rotation)
    let spec: [(CGSize, CGRect, Int)] = [
        (CGSize(width: 612, height: 792), CGRect(x: 36, y: 48, width: 540, height: 700), 0),
        (CGSize(width: 612, height: 792), CGRect(x: 60, y: 90, width: 480, height: 610), 90),
        (CGSize(width: 842, height: 595), CGRect(x: 40, y: 30, width: 760, height: 530), 180),
        (CGSize(width: 396, height: 612), CGRect(x: 24, y: 36, width: 340, height: 540), 270),
    ]
    var first = CGRect(origin: .zero, size: spec[0].0)
    let ctx = CGContext(base as CFURL, mediaBox: &first, nil)!
    for (i, (media, crop, rotation)) in spec.enumerated() {
        var box = CGRect(origin: .zero, size: media)
        let info: [CFString: Any] = [
            kCGPDFContextMediaBox: NSData(bytes: &box, length: MemoryLayout<CGRect>.size),
            kCGPDFContextCropBox: NSData(
                bytes: withUnsafeBytes(of: crop) { Array($0) }, length: MemoryLayout<CGRect>.size
            ),
        ]
        ctx.beginPDFPage(info as CFDictionary)
        // A visible frame just inside the CropBox: anything that mishandles the
        // crop origin lands the frame in the wrong place, visibly.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(2)
        ctx.stroke(crop.insetBy(dx: 6, dy: 6))
        draw(
            ["CORPUSTOKEN-GEOM page \(i + 1)",
             "media \(Int(media.width))x\(Int(media.height)) rotate \(rotation)",
             "crop \(Int(crop.origin.x)),\(Int(crop.origin.y)) \(Int(crop.width))x\(Int(crop.height))"],
            in: ctx,
            startY: crop.maxY - 40,
            size: 14,
            x: crop.origin.x + 20
        )
        ctx.endPDFPage()
    }
    ctx.closePDF()

    // CGPDFContext has no way to write /Rotate; PDFKit does.
    let doc = PDFDocument(url: base)!
    for (i, entry) in spec.enumerated() { doc.page(at: i)!.rotation = entry.2 }
    let out = outDir.appendingPathComponent("rotated-cropped.pdf")
    doc.write(to: out)
    try? FileManager.default.removeItem(at: base)
    report(out)
}

// MARK: - scanned-receipt.pdf
//
// Two image-only pages: a JPEG photograph of text with NO text layer behind it.
// This is the only fixture that makes OCR do real work, the only one Compress can
// genuinely shrink (every other corpus file is lean text, where the save path
// correctly refuses to inflate), and the one where a text search must legitimately
// find nothing.

do {
    let pageSize = CGSize(width: 612, height: 792)
    // Drawn through CoreGraphics/CoreText rather than NSGraphicsContext: this
    // generator runs as a plain command-line binary with no NSApplication, where
    // AppKit's drawing stack traps.
    func scanBitmap(_ lines: [String]) -> CGImage {
        let scale: CGFloat = 2
        let width = Int(pageSize.width * scale)
        let height = Int(pageSize.height * scale)
        let bitmap = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // Off-white, so it looks scanned rather than synthesised — and so
        // Compress's JPEG pass has something to actually work on.
        bitmap.setFillColor(CGColor(gray: 0.94, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setFillColor(CGColor(gray: 0.08, alpha: 1))
        var y = CGFloat(height) - 140
        for line in lines {
            let font = CTFontCreateWithName("Courier" as CFString, 30, nil)
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            bitmap.textPosition = CGPoint(x: 120, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), bitmap)
            y -= 52
        }
        return bitmap.makeImage()!
    }

    let pages = [
        ["NORTHBRIDGE SUPPLY CO", "RECEIPT 88213", "", "CORPUSTOKEN SCAN ONE",
         "Humidity probe      41.00", "Antenna mount       17.50", "TOTAL               58.50"],
        ["NORTHBRIDGE SUPPLY CO", "RECEIPT 88214", "", "CORPUSTOKEN SCAN TWO",
         "Battery cell        92.25", "TOTAL               92.25"],
    ]
    let out = outDir.appendingPathComponent("scanned-receipt.pdf")
    var box = CGRect(origin: .zero, size: pageSize)
    let ctx = CGContext(out as CFURL, mediaBox: &box, nil)!
    for lines in pages {
        // Round-trip through JPEG so the embedded image is a real DCT-encoded
        // photograph, not a lossless bitmap.
        let jpeg = NSMutableData()
        let dest = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, scanBitmap(lines), [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    report(out)
}

// MARK: - encrypted-user.pdf / owner-restricted.pdf
//
// The two encryption shapes the app must tell apart. A user password locks the
// file outright (isLocked). An owner password leaves it readable with no prompt
// yet forbids editing — the shape that silently no-op'd Rotate and Delete before
// `openEditableDocument` was added, so it stays in the corpus as a regression net.

func securePages(_ url: URL, options: [CFString: Any]) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, options as CFDictionary)!
    for page in 1...3 {
        ctx.beginPDFPage(nil)
        draw(
            ["CORPUSTOKEN-SECURE page \(page)", "Confidential — Northbridge internal."],
            in: ctx, startY: 700, size: 18
        )
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

// Locked outright: PDFKit reports isLocked until the user password is supplied.
let userLocked = outDir.appendingPathComponent("encrypted-user.pdf")
securePages(userLocked, options: [
    kCGPDFContextUserPassword: "open-sesame",
    kCGPDFContextOwnerPassword: "owner-sesame",
])
report(userLocked)

// Restrictions only: opens with no prompt, but page assembly is denied.
//
// Written through PDFKit with explicit permission bits, because neither shortcut
// produces this shape. CGPDFContext's owner-password path denies printing and
// copying yet leaves /Assembly permitted; a PDFKit write with only an owner
// password records no permission bits at all. Assembly is precisely the bit
// PDFKit consults before it will rotate or remove a page, so only this
// combination reproduces the file that once made Rotate and Delete no-op in
// silence and still report success.
do {
    let plain = outDir.appendingPathComponent("secure-base.pdf")
    securePages(plain, options: [:])
    // Open and print freely; copying, editing, annotating and assembly all held
    // back — the permission set a statement or corporate report ships with.
    let bits = PDFAccessPermissions.allowsLowQualityPrinting.rawValue
        | PDFAccessPermissions.allowsHighQualityPrinting.rawValue
        | PDFAccessPermissions.allowsContentAccessibility.rawValue
    let out = outDir.appendingPathComponent("owner-restricted.pdf")
    PDFDocument(url: plain)!.write(to: out, withOptions: [
        .ownerPasswordOption: "owner-sesame",
        .accessPermissionsOption: NSNumber(value: bits),
    ])
    try? FileManager.default.removeItem(at: plain)
    report(out)
}
