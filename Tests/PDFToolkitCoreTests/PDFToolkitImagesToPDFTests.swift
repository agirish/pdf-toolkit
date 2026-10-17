import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import PDFToolkitCore

/// Geometry and orientation behavior of the Images to PDF operation: page sizing per mode,
/// EXIF orientation baked in, fit-vs-fill placement (proven by pixel probes), and error cases.
@Suite struct PDFToolkitImagesToPDFTests {

    /// Writes a solid-`gray` PNG of the given pixel size and returns its URL.
    private func writePNG(
        _ name: String,
        width: Int,
        height: Int,
        gray: CGFloat,
        in dir: FixtureDir
    ) throws -> URL {
        let url = dir.url(name)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let ctx = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(white: gray, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }

    /// Writes a JPEG whose pixels are `width`×`height` but whose EXIF orientation says
    /// "rotate 90° CW to display" (orientation 6), so the *displayed* size is `height`×`width`.
    private func writeRotatedJPEG(_ name: String, width: Int, height: Int, in dir: FixtureDir) throws -> URL {
        let plain = try writePNG("plain-\(name).png", width: width, height: height, gray: 0.2, in: dir)
        let source = try #require(CGImageSourceCreateWithURL(plain as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let url = dir.url(name)
        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func matchImagePagesTakeEachImagesExactSize() throws {
        let dir = FixtureDir()
        let landscape = try writePNG("l.png", width: 100, height: 80, gray: 0.5, in: dir)
        let portrait = try writePNG("p.png", width: 80, height: 100, gray: 0.5, in: dir)
        let out = dir.url("out.pdf")

        try PDFToolkit.imagesToPDF(
            inputURLs: [landscape, portrait],
            outputURL: out,
            options: ImagesToPDFOptions(pageSize: .matchImage)
        )

        #expect(try PDFFixtures.pageCount(at: out) == 2)
        #expect(try PDFFixtures.pageSize(at: out, page: 0) == CGSize(width: 100, height: 80))
        #expect(try PDFFixtures.pageSize(at: out, page: 1) == CGSize(width: 80, height: 100))
    }

    @Test func fixedPagesFlipToLandscapeForLandscapeImages() throws {
        let dir = FixtureDir()
        let landscape = try writePNG("l.png", width: 200, height: 100, gray: 0.5, in: dir)
        let portrait = try writePNG("p.png", width: 100, height: 200, gray: 0.5, in: dir)
        let out = dir.url("out.pdf")

        try PDFToolkit.imagesToPDF(
            inputURLs: [landscape, portrait],
            outputURL: out,
            options: ImagesToPDFOptions(pageSize: .usLetter)
        )

        #expect(try PDFFixtures.pageSize(at: out, page: 0) == CGSize(width: 792, height: 612))
        #expect(try PDFFixtures.pageSize(at: out, page: 1) == CGSize(width: 612, height: 792))
    }

    @Test func exifOrientationIsBakedIn() throws {
        let dir = FixtureDir()
        // 120×60 pixels + "rotate 90°" EXIF → displays (and must page) as 60×120.
        let rotated = try writeRotatedJPEG("r.jpg", width: 120, height: 60, in: dir)
        let out = dir.url("out.pdf")

        try PDFToolkit.imagesToPDF(
            inputURLs: [rotated],
            outputURL: out,
            options: ImagesToPDFOptions(pageSize: .matchImage)
        )

        #expect(try PDFFixtures.pageSize(at: out, page: 0) == CGSize(width: 60, height: 120))
        #expect(PDFToolkit.imagePixelSize(at: rotated) == CGSize(width: 60, height: 120))
    }

    @Test func fitLeavesMarginsAndFillCovers() throws {
        let dir = FixtureDir()
        // A square black image on a portrait Letter page: Fit scales to the 612 width, leaving
        // white bands top and bottom; Fill scales to the 792 height, bleeding off the sides.
        let square = try writePNG("sq.png", width: 500, height: 500, gray: 0.0, in: dir)

        let fitOut = dir.url("fit.pdf")
        try PDFToolkit.imagesToPDF(
            inputURLs: [square],
            outputURL: fitOut,
            options: ImagesToPDFOptions(pageSize: .usLetter, fillsPage: false)
        )
        let fit = try PDFFixtures.brightnessSampler(at: fitOut)
        #expect(fit(306, 786) > 0.9, "fit must leave the top band white")
        #expect(fit(306, 396) < 0.1, "fit must draw the image at the center")

        let fillOut = dir.url("fill.pdf")
        try PDFToolkit.imagesToPDF(
            inputURLs: [square],
            outputURL: fillOut,
            options: ImagesToPDFOptions(pageSize: .usLetter, fillsPage: true)
        )
        let fill = try PDFFixtures.brightnessSampler(at: fillOut)
        #expect(fill(306, 786) < 0.1, "fill must cover the top band")
        #expect(fill(306, 396) < 0.1, "fill must cover the center")
        #expect(try PDFFixtures.pageSize(at: fillOut, page: 0) == CGSize(width: 612, height: 792))
    }

    @Test func unreadableFileThrowsCouldNotOpenImage() throws {
        let dir = FixtureDir()
        let bogus = dir.url("not-an-image.png")
        try Data("plain text".utf8).write(to: bogus)

        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.imagesToPDF(
                inputURLs: [bogus],
                outputURL: dir.url("out.pdf"),
                options: ImagesToPDFOptions()
            )
        }
        #expect(error?.kind == "couldNotOpenImage")
    }

    @Test func emptyInputThrowsNoInputFiles() throws {
        let dir = FixtureDir()
        let error = #expect(throws: PDFOperationError.self) {
            try PDFToolkit.imagesToPDF(inputURLs: [], outputURL: dir.url("out.pdf"), options: .init())
        }
        #expect(error?.kind == "noInputFiles")
    }
}
