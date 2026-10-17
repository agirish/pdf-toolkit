import Foundation

public enum PDFOperationError: LocalizedError {
    case couldNotOpen(URL)
    case couldNotWrite(URL)
    case outputMatchesInput(URL)
    case invalidPageRange(String)
    case pageOutOfBounds(Int)
    case pageRangeRequired
    case cannotRemoveEveryPage
    case fileAccessDenied(URL)
    case noInputFiles
    case noPagesSelected
    case compressionFailed
    case emptyPDF
    case noRedactions
    case redactionFailed
    case watermarkTextRequired
    case watermarkImageRequired
    case watermarkFailed
    case noFillSignItems
    case fillSignFailed
    case passwordRequired
    case incorrectPassword
    case notEncrypted
    case protectionFailed
    case metadataEncrypted
    case couldNotOpenImage(URL)
    case cropTooSmall(pageNumber: Int)
    case ocrFailed
    case encryptedInput(URL)
    case permissionsForbidEditing(URL)
    case couldNotEncodeOutput

    public var errorDescription: String? {
        switch self {
        case .couldNotOpen(let url):
            return "Could not open PDF: \(url.lastPathComponent)"
        case .couldNotWrite(let url):
            return "Could not save to: \(url.lastPathComponent)"
        case .outputMatchesInput(let url):
            return "The result would overwrite the original “\(url.lastPathComponent)”. Choose a different location."
        case .invalidPageRange(let s):
            return "Invalid page range: \(s)"
        case .pageOutOfBounds(let n):
            return "Page \(n) is not in this document."
        case .pageRangeRequired:
            return "Enter at least one page number (for example 1 or 2-5)."
        case .cannotRemoveEveryPage:
            return "You cannot remove every page from a PDF. Leave at least one page."
        case .fileAccessDenied(let url):
            return "Could not access “\(url.lastPathComponent)”. Try choosing the file again."
        case .noInputFiles:
            return "Choose at least one PDF file."
        case .noPagesSelected:
            return "Select at least one page."
        case .compressionFailed:
            return "Compression failed while rebuilding the PDF."
        case .emptyPDF:
            return "This PDF has no pages."
        case .noRedactions:
            return "Draw at least one redaction rectangle on a page before saving."
        case .redactionFailed:
            return "Redaction failed while rebuilding the PDF."
        case .watermarkTextRequired:
            return "Enter the watermark text to stamp on each page."
        case .watermarkImageRequired:
            return "Choose an image to stamp as the watermark."
        case .watermarkFailed:
            return "Could not build the watermarked PDF."
        case .noFillSignItems:
            return "Add some text or a signature to a page before saving."
        case .fillSignFailed:
            return "Could not build the filled PDF."
        case .passwordRequired:
            return "Enter a password."
        case .incorrectPassword:
            return "That password did not unlock this PDF. Check it and try again."
        case .notEncrypted:
            return "This PDF is not password-protected, so there is nothing to remove."
        case .protectionFailed:
            return "Could not write the PDF. If the file is open elsewhere, close it and try again."
        case .metadataEncrypted:
            return "This PDF is password-protected, so its metadata can’t be edited. Remove the password with Password Protect first."
        case .couldNotOpenImage(let url):
            return "Could not read the image “\(url.lastPathComponent)”."
        case .cropTooSmall(let page):
            return "That trim would leave almost nothing of page \(page). Use smaller margins."
        case .ocrFailed:
            return "Text recognition failed while rebuilding the PDF."
        case .encryptedInput(let url):
            return "“\(url.lastPathComponent)” is password-protected. Remove its password first (Password Protect → Remove password), then try again."
        case .permissionsForbidEditing(let url):
            return "“\(url.lastPathComponent)” has owner-password restrictions that forbid changing its pages. Remove them first (Password Protect → Remove password), then try again."
        case .couldNotEncodeOutput:
            return "Could not build the result PDF in memory."
        }
    }
}
