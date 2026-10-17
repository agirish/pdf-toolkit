# pdf-toolkit

`PDFToolkitCore` — the PDF engine behind [PDF Utils](https://github.com/agirish/pdf-utils), as a Swift
package with no UI: rotate, delete, reorder, extract, merge, split, crop, compress, clean metadata,
password-protect and remove a password, watermark, redact, fill and sign, images to PDF, and OCR.
macOS 15+, Swift 6.

It was cut from pdf-utils at `7828fcb`. PDF Utils itself now depends on this package, so both apps run
the same code.

```swift
.package(url: "https://github.com/agirish/pdf-toolkit", exact: "0.1.0")
// target dependency:
.product(name: "PDFToolkitCore", package: "pdf-toolkit")
```

The module is `PDFToolkitCore`, not `PDFToolkit`: the main type is `enum PDFToolkit`, and a module named
after one of its own types breaks qualified lookup (`PDFToolkit.rotate` becomes ambiguous). Import the
module and call the type: `import PDFToolkitCore` … `PDFToolkit.rotateData(…)`.

## Threading contract

PDFKit objects are not thread-safe, and two PDFKit parses running at once in one process can change
what PDFKit extracts, not just how fast.

- **Every PDF operation is synchronous** and does all of its PDFKit work on the calling thread.
- **Call them from one serial queue that you own**, and route every other PDFKit use in your process
  through that same queue.
- **The package owns no queue.** It creates no `DispatchQueue`, no `Task` and no actor, so it never
  brings a second serial lane into your process.
- Two functions are `async` and touch no PDFKit object: `imagePixelSizes(for:)` and
  `imagePreview(at:)` read image files with ImageIO, and are safe on any executor.

## The primary API: bytes in, bytes out

Each of these reads the input file and **returns the new file's bytes. None of them writes anything**:
the caller decides where the result goes.

| Operation | Call |
|---|---|
| Rotate | `rotateData(inputURL:pageIndices:quarterTurns:)` |
| Delete pages | `deletePagesData(inputURL:pageIndices:)` |
| Reorder | `reorderData(inputURL:order:)` |
| Extract | `extractData(inputURL:pageIndices:)` |
| Compress | `compressData(inputURL:quality:…)`, `compressDataBounded(inputURL:quality:…)`, `compressToTargetData(inputURL:targetBytes:…)` |
| Clean metadata | `writeMetadataData(inputURL:fields:)` with `PDFMetadataFields` (`.cleared` strips every editable field) |
| Password protect | `encryptData(inputURL:options:)` with `ProtectionOptions` (`.addPassword(restrictEditing:password:)`) |
| Remove password | `removePasswordData(inputURL:password:)` |

`compressDataBounded` is the one to save: it hands back the source's bytes when compressing would not
save at least 5%. `compressData` is the unbounded core, for size estimates. The three compress calls
take optional `onProgress` and `isCancelled` closures, called between pages on the calling thread.

Before a run, these tell you what the file is and what the run would lose:

- `encryptionState(of:)` → `PDFEncryptionState` (`.none`, `.lockedToOpen`, `.restrictedOnly`).
- `hasInteractiveForm(at:)` tells you whether the file has a real catalog `/AcroForm`.
- `OutputFidelityWarning.detect(in:formLoss:checksBookmarks:)` says whether a run will flatten or orphan
  a form, or drop bookmarks, with the user-facing wording (`headline`, `detailLines(toolTitle:)`,
  `detail(toolTitle:)`).

Supporting types: `PageRangeParser` (`"1, 3-5"` → zero-based indices), `PDFOperationError`
(`LocalizedError`, user-facing messages), `CropInsets`, `PDFMetadataFields`, `ProtectionOptions`.

Every operation also has a URL-to-URL form (`rotate(inputURL:outputURL:…)` and so on). Those wrap the
Data variant, refuse to write over their own input, and write atomically.

The rest of the public surface (watermark, redact, fill and sign, crop, split, merge, images to PDF,
OCR, find-to-redact, and their option types) is public because PDF Utils calls it. It works the same
way, but it is not part of what this package was cut for.

## Known limitation: OCR on a single-queue host

`ocrData` runs Vision text recognition **inside** its PDFKit section: it renders a page, recognizes it,
and writes the text layer in one synchronous call per document. On a host that funnels all PDFKit work
through one queue, a long OCR run holds that queue for the whole recognition pass. Splitting the
Vision work out of the PDFKit section would fix that, and is not done here.

## Files and sandboxing

Inputs are plain file URLs. A few readers (the image-size and preview readers, the watermark logo
decoder, and `OutputFidelityWarning.detect`) open the URL's security scope around the read
(`withSecurityScopedAccess`). In an unsandboxed process that call succeeds for an ordinary file URL,
so callers there need do nothing special.

## Tests

```bash
swift test
```

Most fixtures are written at run time, but a small committed corpus of real PDFs covers the corner
cases Apple's own writer cannot produce: a browser-produced document, a fillable form inside a
compressed cross-reference stream, a nested outline, rotated pages cropped off the origin, a scan,
and both kinds of encryption. See [docs/testing-corpus.md](docs/testing-corpus.md), and
`scripts/corpus/generate.sh` to regenerate it.

**On macOS 27.0.1, 31 of the 445 tests fail** (61 issues). Every one is about something surviving a
PDFKit write: bookmarks, link annotations, or Info-dictionary fields. Some fail on the test's own
fixture, before any engine call runs. The same 31 fail, with identical messages, in pdf-utils at
`7828fcb`, the commit this package was cut from, so the move did not cause them. The likely cause is a
change in the OS's PDFKit, and it has not been investigated yet.

## License

Not yet chosen. Add a `LICENSE` file before anyone outside this project depends on it.
