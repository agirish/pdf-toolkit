# The real-PDF corpus

Seven PDF files live under
`Tests/PDFToolkitCoreTests/Corpus/`. They are committed to the
repository, loaded through `Bundle.module`, and exercised end-to-end by
`RealCorpusTests.swift`.

## Why they exist

Every other fixture in the suite is built at run time out of a `CGPDFContext`.
That is the right default — a test that writes its own input states exactly the
shape it needs — but it means, until this corpus, every input the suite had ever
seen came from one producer in one style:

- a plain cross-reference table, never a cross-reference *stream*
- no object streams, so every object was readable without inflating anything
- no embedded font programs
- no catalog `/AcroForm`, because **PDFKit's writer will not emit one** — a
  fixture built from `PDFAnnotation(forType: .widget)` reports
  `hasInteractiveForm == false` and silently tests nothing
- no encryption dictionary the app had not written itself
- upright pages whose boxes started at the origin

Three shipped geometry bugs hid behind that last point alone. The corpus covers
the gap with the smallest set of files that still reaches every corner case the
tools warn about.

## The files

| File | Pages | What it is kept for |
| --- | --- | --- |
| `chrome-article.pdf` | 3 | Produced by Chrome's Skia backend — the only input in the suite Apple did not write. Embedded subset fonts, real internal/external/mailto link annotations, and the seeded card number and email the Find & redact tests search for. |
| `acroform-xrefstream.pdf` | 2 | A genuine catalog `/AcroForm` (text field + checkbox, both with appearance streams) inside a PDF 1.6 **object stream** behind a **cross-reference stream**, plus an XMP `/Metadata` packet and a full Info dictionary. The only file whose objects must be inflated before the catalog is visible. |
| `outline-nested.pdf` | 6 | A **nested** outline: 3 top-level entries, one with 3 children, plus a document title and an internal link. A flat outline cannot tell "kept the tree" from "kept a list". |
| `rotated-cropped.pdf` | 4 | Three page sizes, four different `/Rotate` values, every crop box smaller than its media box **and at a non-zero origin**. |
| `scanned-receipt.pdf` | 2 | Image-only: a JPEG of printed text with no text layer. The only file that makes OCR do real work, the only one Compress can genuinely shrink, and the one where a text search must legitimately find nothing. |
| `encrypted-user.pdf` | 3 | A user password (`open-sesame`): `isLocked`, unreadable until unlocked. |
| `owner-restricted.pdf` | 3 | An owner password with explicit permission bits: opens with no prompt, is not `isLocked`, but **assembly is denied**. The shape that once let Rotate and Delete silently no-op and still report success. |

None of these files contains real personal data. Every name, card number and
email in them is invented — `4111 1111 1111 1111` is the industry's published
test card, Luhn-valid and issued to no one.

## Regenerating

```bash
scripts/corpus/generate.sh
```

Three generators feed it, split by what each file has to be real *about*:

- `make_structural.py` byte-authors the files whose **file structure** is the
  point. Neither PDFKit nor CoreGraphics can produce a cross-reference stream, an
  object stream, or a catalog `/AcroForm`, so those are assembled by hand.
- `make_rendered.swift` renders the files that need a real drawing engine or a
  real encryptor — genuine glyph runs, a genuine JPEG, real encryption
  dictionaries. Compiled with `swiftc` rather than run as a `swift` script: the
  interpreter traps inside AppKit here.
- Chrome headless prints `article.html`. If Chrome is not installed the step is
  skipped with a warning and the committed copy is left in place.

The corpus is **not** regenerated during `swift test`. CI must not depend on
Chrome being installed, and a fixture rebuilt on every run can drift silently
underneath the assertions that describe it.

Encryption uses fresh random keys, so the two encrypted files differ byte-for-byte
on every regeneration even when nothing about them changed. Regenerate
deliberately, not as a habit.

## Adding a file

Keep the set small — it is committed, and `RealCorpusIntegrityTests` caps the
total at 512 KB (currently ~260 KB). Before adding one, check that no existing
file can carry the trait instead.

1. Add the generator step to the appropriate script.
2. Add a case to the `RealCorpus` enum with a comment saying what corner case it
   is kept for, and its entry in `RealCorpus.traits`.
3. Run `scripts/corpus/generate.sh`, commit the binary, and update this table.

`RealCorpusIntegrityTests` asserts every declared trait, so a file that was
regenerated into a different shape fails once and loudly rather than as a scatter
of confusing downstream failures.
