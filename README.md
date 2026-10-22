# pdf-toolkit

`PDFToolkitCore` — the PDF engine behind [PDF Utils](https://github.com/agirish/pdf-utils), as a Swift
package with no UI: rotate, delete, reorder, extract, merge, split, crop, compress, clean metadata,
password-protect and remove a password, watermark, redact, fill and sign, fill a form in place,
images to PDF, and OCR.
macOS 15+, Swift 6.

It was cut from pdf-utils at `7828fcb`. PDF Utils itself now depends on this package, so both apps run
the same code.

```swift
.package(url: "https://github.com/agirish/pdf-toolkit", exact: "0.5.0")
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
| List form fields | `formFields(at:)` → `[FormField]` (reads only; returns no bytes) |
| Fill a form, keeping it fillable | `fillFormData(inputURL:values:items:)` with `[String: FormFieldValue]` — see [Forms](#forms) |

`compressDataBounded` is the one to save: it hands back the source's bytes when compressing would not
save at least 5%. `compressData` is the unbounded core, for size estimates. The three compress calls
take optional `onProgress` and `isCancelled` closures, called between pages on the calling thread.

Before a run, these tell you what the file is and what the run would lose:

- `encryptionState(of:)` → `PDFEncryptionState` (`.none`, `.lockedToOpen`, `.restrictedOnly`).
- `hasInteractiveForm(at:)` tells you whether the file has a real catalog `/AcroForm`.
- `OutputFidelityWarning.detect(in:formLoss:checksBookmarks:)` says whether a run will flatten or orphan
  a form, or drop bookmarks, with the user-facing wording (`headline`, `detailLines(toolTitle:)`,
  `detail(toolTitle:)`).
- `droppedCatalogParts(at:)` → `[DroppedCatalogPart]` (`.tags`, `.layers`, `.outputIntent`): what the
  file has that no copy keeps (see [What a copy keeps](#what-a-copy-keeps)).

Supporting types: `PageRangeParser` (`"1, 3-5"` → zero-based indices), `PDFOperationError`
(`LocalizedError`, user-facing messages), `CropInsets`, `PDFMetadataFields`, `ProtectionOptions`,
`FormField`, `FormFieldValue`.

Every operation also has a URL-to-URL form (`rotate(inputURL:outputURL:…)` and so on). Those wrap the
Data variant, refuse to write over their own input, and write atomically.

The rest of the public surface (watermark, redact, fill and sign, crop, split, merge, images to PDF,
OCR, find-to-redact, and their option types) is public because PDF Utils calls it. It works the same
way, but it is not part of what this package was cut for.

## What a copy keeps

Every tool's copy keeps the pages, bookmarks, links, the info dictionary's Title, Author, Subject,
Keywords and Creator, and these catalog entries, which PDFKit's writer can't set and which are
written in an appended incremental update:

- **page labels** ("i, ii, 1, 2", "A-1"). Each page keeps its own label, so an extract of "iii" and
  "4" still reads "iii" and "4", and a deleted or reordered page takes its label with it;
- **viewer settings**: page layout, page mode, viewer preferences, and the opening view. A view on a
  page the copy lacks opens the copy's first page at the same zoom. A script run on opening is not
  carried;
- **the language**;
- **attached files**, the document's and each page's (FileAttachment annotations, file and all).
  A redaction with marks keeps none, since a file can hold what was painted over.

Tags (`/StructTreeRoot`, `/MarkInfo`), layers (`/OCProperties`) and the colour output intent
(`/OutputIntents`) are not kept by a copy that rebuilds or re-copies its pages: tags and layers name
page content by marked-content ids a rebuilt page no longer has, and an output intent claims a
conformance the copy no longer meets. `droppedCatalogParts(at:)` says which a file has. Rotate,
Protect and filling a form write the document in place and keep everything. Merge and Split carry
none of these.

## Forms

`formFields(at:)` lists a PDF's interactive fields: fully qualified name (`applicant.name`), kind,
current value, options, read-only, `/MaxLen`, `isFillable`, and every widget with its page and
rectangle (page space, y-up, like `FillSignItem.rect`). `fillFormData(inputURL:values:items:)`
fills them **in place** and returns bytes whose form is still fillable.

**Fill or flatten.** `fillAndSignData` redraws every page, so the form becomes page content and can
no longer be filled; that is right for a finished form. `fillFormData` changes the document opened
from the file, so the catalog `/AcroForm`, every widget, the outline, links, XMP, Info and any
encryption survive. Its `items` (placed text and drawn signatures) become FreeText and Ink
annotations, not page content.

**Faces.** `FillSignText.font` names the face a run is drawn in (`.named("SavoyeLetPlain")`, or the
system font's rounded or monospaced design); `nil`, or a face the Mac lacks, is the default — a
script chain for a typed signature, the system font for text. Both paths embed the face. Measured
2026-10-19 in Preview, Chrome and Acrobat: a FreeText annotation loses glyphs CoreText reaches only
by ligature (SignPainter's "ir" and "or"), and a face known only by a private name (New York) cannot
be named in one, so it comes out as Helvetica. Text drawn into the page keeps both.

**Patches.** `FillSignItem.Content.patch(FillSignPatch)` is a rectangle filled with an sRGB colour: the
cover under a correction, with a text run placed over it. `fillAndSignData` draws a page's patches
before its text and signatures, whatever the order of `items`. A patch hides what is under it and
removes nothing: the covered words stay in the page's text, and search and copy still find them. To
remove them, rasterize the page with `redactData(inputURL:marks:options:)` and `forceRasterizePages`.
`fillFormData` adds a patch as a borderless Square annotation, before the page's other new items so
they are drawn over it; any app can delete it.

**Permissions.** Filling needs `allowsFormFieldEntry`, not `allowsDocumentAssembly`: many forms
forbid editing but allow filling (one real form surveyed for this release carries `0xf7`: form entry yes, assembly no).
`items` also need `allowsCommenting`. Either missing throws `permissionsForbidEditing`; a locked file
throws `encryptedInput`. PDFKit drops a forbidden change without an error, so the result is reopened
and read back before it is returned.

**Refused, never skipped:** an unknown name, a read-only field, a signature or push-button field, a
value of the wrong kind, a choice outside the options (unless the combo is editable), a radio value
that is not an export value, text longer than `/MaxLen`, and a choice whose `/Opt` items are
`[export display]` pairs (PDFKit lists their display text and would write it into `/V`, where the
export value belongs). Every value is checked before anything changes.

**What other readers see** (measured on macOS 27.0.1):

- **Text and choice fields:** PDFKit rewrites `/V` and regenerates the appearance stream, but only
  for the widgets it is handed. A field with a widget on two pages otherwise shows the new value on
  one page and the old one on the other, so the value is set on every widget.
- **Checkboxes and radio buttons:** PDFKit's writer cannot set them. It replaces the producer's on/off
  appearances with one stream, writes `/V` as a string, and leaves `/AS` naming the old state; on
  reopen, PDFKit itself reads the radio group as all off. So buttons are left alone in PDFKit and
  their `/AS` and `/V` are set as names in an appended incremental update. The producer's
  appearances are kept. Names are never encrypted, so this works on an encrypted file too.
  PDFKit on macOS 26 writes each widget twice, once for the page and once under the field tree,
  and reads the field back from the tree, so both copies are set.
- No `/NeedAppearances` is set: every changed widget has an appearance showing its new value.
- **Checking it yourself:** PDFKit draws a widget from `/V`, not from its appearance stream. Preview,
  a `PDFView`, or flattening through this package shows the new value even when the appearance is
  stale, so none of them tell you what Acrobat or Chrome shows. The tests read the appearance
  streams directly.
- **Placed items:** PDFKit writes real appearance streams for FreeText (the text) and Ink (the
  strokes) but writes no `/DA` for FreeText, which a viewer needs only to edit that text. On a page
  with a `/Rotate`, PDFKit's FreeText appearance would show sideways, so typed text there throws
  `textOnRotatedPage`; a drawn signature is fine.
- **XFA:** a form that also carries `/XFA` data (common in older government forms) is filled in its
  AcroForm only. Acrobat may show the XFA data instead.

**Do not hand a heavy form to a `PDFView`.** PDFKit starts a `formFillingQueue` thread per field: a
scanned government form with hundreds of fields was measured at 500+ threads and about 2.6 GB (see
`interactivePreviewDocument(from:)`). These calls never mount one.

**Keep form work on your one serial queue.** Parsing a widget looks up its `/DA` font through the
font registry, which on macOS 27.0.1 deadlocks when every Swift-concurrency pool thread does it at
once (the test suite hit it in 3 runs of 25 before its form tests moved to one lane; see
`FormLane` in the tests). The threading contract above already rules this out.

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
compressed cross-reference stream, a form with every field kind, a nested outline, rotated pages
cropped off the origin, a scan, and both kinds of encryption. See [docs/testing-corpus.md](docs/testing-corpus.md), and
`scripts/corpus/generate.sh` to regenerate it.

All 510 tests pass on macOS 27.0.1; CI runs them on a hosted macOS 26 runner. (0.1.0 had 31 failures there, all about bookmarks, links or Info
fields surviving a PDFKit write; 0.1.1 fixed them.)

## License

Not yet chosen. Add a `LICENSE` file before anyone outside this project depends on it.
