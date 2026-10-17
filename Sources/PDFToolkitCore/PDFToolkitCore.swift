// PDFToolkitCore — PDF operations on files, with no UI.
//
// THREADING CONTRACT
//
// PDFKit objects (`PDFDocument`, `PDFPage`, `PDFSelection`, …) are not thread-safe. Two parses
// running at once in one process are not merely slower: they can change what PDFKit extracts.
//
// - Every PDF operation here is synchronous and does all of its PDFKit work on the calling
//   thread. Call them from ONE serial queue that you own, and run every other PDFKit use in
//   your process through that same queue.
// - The package owns no queue. It creates no `DispatchQueue`, no `Task`, and no actor, so it
//   can never bring a second serial lane into your process.
// - The two exceptions are `async` and touch no PDFKit object: `PDFToolkit.imagePixelSizes(for:)`
//   and `PDFToolkit.imagePreview(at:)` read image files with ImageIO, and are safe to call from
//   any executor.
// - OCR (`PDFToolkit.ocrData`) runs Vision text recognition INSIDE its PDFKit section, so on a
//   single-queue host it holds that queue for the whole recognition pass. See the README.
//
// THE PRIMARY API
//
// The `…Data` variants: they read the input URL and return the new file's bytes, and write nothing.
// The caller decides where those bytes go. The URL-to-URL variants (`rotate(inputURL:outputURL:…)`
// etc.) are thin wrappers that also refuse to overwrite their input and write atomically.
