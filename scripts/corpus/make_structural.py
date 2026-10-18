#!/usr/bin/env python3
"""Byte-authors the corpus PDFs whose *file structure* is the point.

PDFKit's writer and CoreGraphics both emit plain cross-reference tables and
neither will produce a catalog `/AcroForm`, so the structures real-world
producers use most — a PDF 1.5+ cross-reference *stream* with the catalog,
pages and form fields packed into an *object stream* — cannot be reached
through any Apple API. Those files are assembled here, byte by byte, so the
suite has at least one input whose objects the parser must inflate before it
can see them.

Run via scripts/corpus/generate.sh; output lands in the test target's Corpus/.
"""

import struct
import sys
import zlib
from pathlib import Path


def flate(data: bytes) -> bytes:
    return zlib.compress(data, 9)


class Builder:
    """Assembles a PDF whose objects live in an object stream behind an xref stream.

    Objects are added as either `direct` (serialised inside the object stream —
    dictionaries and arrays only, since PDF forbids streams there) or `stream`
    (emitted at top level with its own offset).
    """

    def __init__(self, version=b"1.6"):
        self.version = version
        self.direct = {}   # obj number -> bytes (no "N 0 obj" wrapper)
        self.streams = {}  # obj number -> (dict bytes, payload bytes)

    def add_direct(self, num, body: str):
        self.direct[num] = body.encode("latin-1")

    def add_stream(self, num, dict_body: str, payload: bytes, compress=True):
        if compress:
            payload = flate(payload)
            dict_body = dict_body.rstrip() + " /Filter /FlateDecode"
        self.streams[num] = (
            f"<< {dict_body} /Length {len(payload)} >>".encode("latin-1"),
            payload,
        )

    def build(self, root: int, info: int, objstm_num: int, xref_num: int) -> bytes:
        # --- pack the direct objects into one object stream -------------------
        nums = sorted(self.direct)
        offsets, body = [], b""
        for n in nums:
            offsets.append((n, len(body)))
            body += self.direct[n] + b"\n"
        header = " ".join(f"{n} {off}" for n, off in offsets).encode("latin-1") + b"\n"
        payload = flate(header + body)
        objstm = (
            f"<< /Type /ObjStm /N {len(nums)} /First {len(header)} "
            f"/Filter /FlateDecode /Length {len(payload)} >>".encode("latin-1"),
            payload,
        )

        # --- lay out the file -------------------------------------------------
        out = b"%PDF-" + self.version + b"\n%\xe2\xe3\xcf\xd3\n"
        top_offsets = {}
        for n in sorted(self.streams) + [objstm_num]:
            d, p = self.streams[n] if n != objstm_num else objstm
            top_offsets[n] = len(out)
            out += f"{n} 0 obj\n".encode("latin-1") + d + b"\nstream\n" + p + b"\nendstream\nendobj\n"

        size = max(list(self.streams) + list(self.direct) + [objstm_num, xref_num]) + 1

        # --- the cross-reference stream itself --------------------------------
        # Type 1 = at a byte offset; type 2 = inside an object stream.
        xref_offset = len(out)
        rows = [b"\x00" + struct.pack(">I", 0) + b"\xff\xff"]  # free head
        for n in range(1, size):
            if n in top_offsets:
                rows.append(b"\x01" + struct.pack(">I", top_offsets[n]) + b"\x00\x00")
            elif n == xref_num:
                rows.append(b"\x01" + struct.pack(">I", xref_offset) + b"\x00\x00")
            elif n in self.direct:
                idx = nums.index(n)
                rows.append(b"\x02" + struct.pack(">I", objstm_num) + struct.pack(">H", idx))
            else:
                rows.append(b"\x00" + struct.pack(">I", 0) + b"\xff\xff")
        xref_payload = flate(b"".join(rows))
        xref_dict = (
            f"<< /Type /XRef /Size {size} /W [1 4 2] /Root {root} 0 R /Info {info} 0 R "
            f"/Filter /FlateDecode /Length {len(xref_payload)} >>"
        ).encode("latin-1")
        out += (
            f"{xref_num} 0 obj\n".encode("latin-1")
            + xref_dict
            + b"\nstream\n" + xref_payload + b"\nendstream\nendobj\n"
            + f"startxref\n{xref_offset}\n%%EOF\n".encode("latin-1")
        )
        return out


XMP = """<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
    xmlns:xmp="http://ns.adobe.com/xap/1.0/">
   <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Northbridge Access Request</rdf:li></rdf:Alt></dc:title>
   <dc:creator><rdf:Seq><rdf:li>CORPUS-XMP-AUTHOR</rdf:li></rdf:Seq></dc:creator>
   <pdf:Producer>CORPUS-XMP-PRODUCER</pdf:Producer>
   <xmp:CreatorTool>CORPUS-XMP-TOOL</xmp:CreatorTool>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>""".encode("utf-8")


def acroform_xrefstream() -> bytes:
    """A two-page fillable form: real catalog /AcroForm, compressed structure, XMP packet.

    Both field kinds are present because they fail differently: a text field
    carries its value in /V, a checkbox carries an /AS appearance state. Each has
    a real appearance stream, so the "flattened" outcome (appearance painted into
    the page, interactivity gone) is visually verifiable rather than nominal.
    """
    b = Builder()
    content1 = (
        b"BT /Helv 18 Tf 72 720 Td (CORPUSTOKEN-FORM Access Request) Tj ET\n"
        b"BT /Helv 11 Tf 72 660 Td (Full name:) Tj ET\n"
        b"BT /Helv 11 Tf 72 610 Td (I agree to the terms:) Tj ET\n"
    )
    content2 = b"BT /Helv 11 Tf 72 720 Td (CORPUSTOKEN-FORM page two, no fields here.) Tj ET\n"

    b.add_direct(1, "<< /Type /Catalog /Pages 2 0 R /Metadata 8 0 R "
                    "/AcroForm << /Fields [6 0 R 7 0 R] /DA (/Helv 0 Tf 0 g) "
                    "/DR << /Font << /Helv 5 0 R >> >> /NeedAppearances false >> >>")
    b.add_direct(2, "<< /Type /Pages /Kids [3 0 R 12 0 R] /Count 2 >>")
    b.add_direct(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                    "/Annots [6 0 R 7 0 R] /Contents 4 0 R "
                    "/Resources << /Font << /Helv 5 0 R >> >> >>")
    b.add_direct(12, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                     "/Contents 13 0 R /Resources << /Font << /Helv 5 0 R >> >> >>")
    b.add_direct(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    b.add_direct(6, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (FullName) /V (Dana Reyes) "
                    "/Rect [160 655 420 679] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /AP << /N 9 0 R >> >>")
    b.add_direct(7, "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) /V /Yes /AS /Yes "
                    "/Rect [200 605 216 621] /DA (/ZaDb 0 Tf 0 g) /F 4 /P 3 0 R "
                    "/MK << /BC [0 0 0] >> /AP << /N << /Yes 10 0 R /Off 11 0 R >> >> >>")
    b.add_direct(14, "<< /Title (Northbridge Access Request) /Author (CORPUS-INFO-AUTHOR) "
                     "/Subject (Fillable form corpus fixture) /Keywords (corpus, acroform, xrefstream) "
                     "/Creator (CORPUS-INFO-CREATOR) /Producer (CORPUS-INFO-PRODUCER) >>")

    b.add_stream(4, "", content1)
    b.add_stream(13, "", content2)
    b.add_stream(8, "/Type /Metadata /Subtype /XML", XMP, compress=False)
    b.add_stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 260 24] "
                    "/Resources << /Font << /Helv 5 0 R >> >>",
                 b"/Tx BMC q BT /Helv 11 Tf 0 g 2 7 Td (Dana Reyes) Tj ET Q EMC")
    b.add_stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 16 16]",
                 b"q 0 g 2 2 m 6 6 l 13 13 l S Q")
    b.add_stream(11, "/Type /XObject /Subtype /Form /BBox [0 0 16 16]", b"")
    return b.build(root=1, info=14, objstm_num=15, xref_num=16)


def classic_pdf(objects: dict, root: int, info: int) -> bytes:
    """Lays out `objects` (number -> body bytes, streams already wrapped) behind a
    plain cross-reference TABLE — the other structure real forms ship in, so the
    form corpus is not all object streams."""
    out = b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"
    offsets = {}
    for n in sorted(objects):
        offsets[n] = len(out)
        out += f"{n} 0 obj\n".encode("latin-1") + objects[n] + b"\nendobj\n"
    size = max(objects) + 1
    xref = len(out)
    out += f"xref\n0 {size}\n0000000000 65535 f \n".encode("latin-1")
    for n in range(1, size):
        if n in offsets:
            out += f"{offsets[n]:010d} 00000 n \n".encode("latin-1")
        else:
            out += b"0000000000 65535 f \n"
    out += (f"trailer\n<< /Size {size} /Root {root} 0 R /Info {info} 0 R >>\n"
            f"startxref\n{xref}\n%%EOF\n").encode("latin-1")
    return out


def acroform_fieldkinds() -> bytes:
    """Every field kind a fill call has to handle, in one two-page form.

    Text (nested under a parent, so the fully qualified name is `applicant.name`),
    multiline with /MaxLen, read-only, a checkbox that starts Off, a three-way
    radio group, a combo box, an editable combo, a list box, a combo whose items
    are [export display] pairs, a signature field and a push button — plus `initials`, ONE field with a widget on each page, which is
    the shape where a fill that updates only the first widget looks right on page 1
    and stale on page 2. Every widget carries an appearance stream, as a real
    producer writes it. An outline, an internal link, an XMP packet and an Info
    dictionary ride along so a fill can be checked for keeping all of them.

    Plain cross-reference table, unlike acroform-xrefstream.pdf.
    """
    objs = {}

    def obj(n, body: str):
        objs[n] = body.encode("latin-1")

    def stream(n, dict_body: str, payload: bytes):
        objs[n] = (f"<< {dict_body} /Length {len(payload)} >>\nstream\n".encode("latin-1")
                   + payload + b"\nendstream")

    def text_ap(n, w, h, value: str):
        stream(n, f"/Type /XObject /Subtype /Form /BBox [0 0 {w} {h}] "
                  "/Resources << /Font << /Helv 5 0 R >> >>",
               f"/Tx BMC q BT /Helv 11 Tf 0 g 2 {h / 2 - 4:g} Td ({value}) Tj ET Q EMC".encode("latin-1"))

    check_on = b"q 0 G 0.5 0.5 15 15 re S Q q 0 g BT /ZaDb 12 Tf 2.5 3.5 Td (4) Tj ET Q"
    box_off = b"q 0 G 0.5 0.5 15 15 re S Q"
    dot_on = b"q 0 G 0.5 0.5 15 15 re S Q q 0 g 4 4 8 8 re f Q"
    zadb_res = "/Resources << /Font << /ZaDb 6 0 R >> >>"

    page1 = (
        b"BT /Helv 18 Tf 72 740 Td (CORPUSTOKEN-FIELDS Membership Form) Tj ET\n"
        b"BT /Helv 11 Tf 72 698 Td (Name:) Tj ET\n"
        b"BT /Helv 11 Tf 72 658 Td (Initials:) Tj ET\n"
        b"BT /Helv 11 Tf 72 620 Td (Notes:) Tj ET\n"
        b"BT /Helv 11 Tf 72 528 Td (Account:) Tj ET\n"
        b"BT /Helv 11 Tf 72 486 Td (Subscribe:) Tj ET\n"
        b"BT /Helv 11 Tf 72 446 Td (Plan: basic / plus / pro) Tj ET\n"
        b"BT /Helv 11 Tf 72 408 Td (Country:) Tj ET\n"
        b"BT /Helv 11 Tf 72 360 Td (Colour:) Tj ET\n"
        b"BT /Helv 11 Tf 72 258 Td (Title:) Tj ET\n"
        b"BT /Helv 11 Tf 72 186 Td (Signature:) Tj ET\n"
        b"BT /Helv 11 Tf 72 78 Td (Go to page two) Tj ET\n"
    )
    page2 = (
        b"BT /Helv 18 Tf 72 740 Td (CORPUSTOKEN-FIELDS page two) Tj ET\n"
        b"BT /Helv 11 Tf 72 706 Td (Initials again:) Tj ET\n"
    )

    obj(1, "<< /Type /Catalog /Pages 2 0 R /Metadata 7 0 R /Outlines 60 0 R "
           "/AcroForm << /Fields [20 0 R 22 0 R 25 0 R 27 0 R 29 0 R 31 0 R 36 0 R 38 0 R 40 0 R 44 0 R 42 0 R 43 0 R] "
           "/DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R /ZaDb 6 0 R >> >> >> >>")
    obj(2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
    obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 8 0 R "
           "/Resources << /Font << /Helv 5 0 R >> >> "
           "/Annots [21 0 R 23 0 R 25 0 R 27 0 R 29 0 R 32 0 R 33 0 R 34 0 R 36 0 R 38 0 R 40 0 R 44 0 R 42 0 R 43 0 R 50 0 R] >>")
    obj(4, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 9 0 R "
           "/Resources << /Font << /Helv 5 0 R >> >> /Annots [24 0 R] >>")
    obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    obj(6, "<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>")
    stream(7, "/Type /Metadata /Subtype /XML", XMP.replace(b"Northbridge Access Request", b"Membership Form"))
    stream(8, "", page1)
    stream(9, "", page2)
    obj(10, "<< /Title (Membership Form) /Author (CORPUS-INFO-AUTHOR) /Subject (Every field kind) "
            "/Keywords (corpus, acroform, fields) /Creator (CORPUS-INFO-CREATOR) /Producer (CORPUS-INFO-PRODUCER) >>")

    # applicant.name — a nested text field: the parent holds the partial name only.
    obj(20, "<< /T (applicant) /Kids [21 0 R] >>")
    obj(21, "<< /Type /Annot /Subtype /Widget /Parent 20 0 R /FT /Tx /T (name) /V (Ada Quill) "
            "/Rect [200 692 420 712] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /AP << /N 70 0 R >> >>")
    text_ap(70, 220, 20, "Ada Quill")

    # initials — one field, one widget per page.
    obj(22, "<< /FT /Tx /T (initials) /V (AQ) /DA (/Helv 11 Tf 0 g) /Kids [23 0 R 24 0 R] >>")
    obj(23, "<< /Type /Annot /Subtype /Widget /Parent 22 0 R /Rect [200 652 260 672] /F 4 /P 3 0 R /AP << /N 71 0 R >> >>")
    obj(24, "<< /Type /Annot /Subtype /Widget /Parent 22 0 R /Rect [200 700 260 720] /F 4 /P 4 0 R /AP << /N 72 0 R >> >>")
    text_ap(71, 60, 20, "AQ")
    text_ap(72, 60, 20, "AQ")

    # notes — multiline (Ff bit 13) with /MaxLen.
    obj(25, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (notes) /Ff 4096 /MaxLen 200 /V (First line) "
            "/Rect [200 560 500 640] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /AP << /N 73 0 R >> >>")
    text_ap(73, 300, 80, "First line")

    # account — read-only (Ff bit 1).
    obj(27, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (account) /Ff 1 /V (ACCT-0042) "
            "/Rect [200 522 420 542] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /AP << /N 74 0 R >> >>")
    text_ap(74, 220, 20, "ACCT-0042")

    # subscribe — a checkbox that starts Off, export value /Yes.
    obj(29, "<< /Type /Annot /Subtype /Widget /FT /Btn /T (subscribe) /V /Off /AS /Off "
            "/Rect [200 482 216 498] /DA (/ZaDb 0 Tf 0 g) /F 4 /P 3 0 R /MK << /CA (4) >> "
            "/AP << /N << /Yes 75 0 R /Off 76 0 R >> >> >>")
    stream(75, f"/Type /XObject /Subtype /Form /BBox [0 0 16 16] {zadb_res}", check_on)
    stream(76, "/Type /XObject /Subtype /Form /BBox [0 0 16 16]", box_off)

    # plan — radio group (Ff radio + no-toggle-to-off), three kids, /plus chosen.
    obj(31, "<< /FT /Btn /T (plan) /Ff 49152 /V /plus /DA (/ZaDb 0 Tf 0 g) /Kids [32 0 R 33 0 R 34 0 R] >>")
    for n, x, state in ((32, 200, "basic"), (33, 260, "plus"), (34, 320, "pro")):
        on = state == "plus"
        obj(n, f"<< /Type /Annot /Subtype /Widget /Parent 31 0 R /Rect [{x} 442 {x + 16} 458] /F 4 /P 3 0 R "
               f"/AS /{state if on else 'Off'} /MK << /CA (l) >> "
               f"/AP << /N << /{state} 77 0 R /Off 76 0 R >> >> >>")
    stream(77, "/Type /XObject /Subtype /Form /BBox [0 0 16 16]", dot_on)

    # country — a combo box (Ff bit 18), not editable.
    obj(36, "<< /Type /Annot /Subtype /Widget /FT /Ch /T (country) /Ff 131072 "
            "/Opt [(Canada) (France) (Japan)] /V (France) "
            "/Rect [200 402 360 422] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /AP << /N 78 0 R >> >>")
    text_ap(78, 160, 20, "France")

    # colour — a list box (no combo flag).
    obj(38, "<< /Type /Annot /Subtype /Widget /FT /Ch /T (colour) "
            "/Opt [(Red) (Green) (Blue)] /V (Green) "
            "/Rect [200 320 360 380] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /AP << /N 79 0 R >> >>")
    stream(79, "/Type /XObject /Subtype /Form /BBox [0 0 160 60] /Resources << /Font << /Helv 5 0 R >> >>",
           b"/Tx BMC q BT /Helv 11 Tf 0 g 2 46 Td (Red) Tj 0 -18 Td (Green) Tj 0 -18 Td (Blue) Tj ET Q EMC")

    # title — an EDITABLE combo (Ff combo + edit), which accepts a value not in /Opt.
    obj(40, "<< /Type /Annot /Subtype /Widget /FT /Ch /T (title) /Ff 393216 "
            "/Opt [(Dr) (Mr) (Ms)] /V (Ms) "
            "/Rect [200 252 300 272] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /AP << /N 80 0 R >> >>")
    text_ap(80, 100, 20, "Ms")

    # size — a combo whose /Opt items are [export display] pairs: /V holds the export value.
    obj(44, "<< /Type /Annot /Subtype /Widget /FT /Ch /T (size) /Ff 131072 "
            "/Opt [[(s) (Small)] [(m) (Medium)] [(l) (Large)]] /V (m) "
            "/Rect [430 252 530 272] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /AP << /N 82 0 R >> >>")
    text_ap(82, 100, 20, "Medium")

    # signature and reset — listed, never fillable.
    obj(42, "<< /Type /Annot /Subtype /Widget /FT /Sig /T (signature) "
            "/Rect [200 170 420 210] /F 4 /P 3 0 R >>")
    obj(43, "<< /Type /Annot /Subtype /Widget /FT /Btn /T (reset) /Ff 65536 "
            "/Rect [430 170 510 190] /DA (/Helv 11 Tf 0 g) /F 4 /P 3 0 R /MK << /CA (Reset) >> "
            "/A << /S /ResetForm >> /AP << /N 81 0 R >> >>")
    text_ap(81, 80, 20, "Reset")

    # An internal link to page two, and a two-entry outline.
    obj(50, "<< /Type /Annot /Subtype /Link /Rect [72 72 200 90] /Border [0 0 0] /Dest [4 0 R /XYZ 0 792 0] >>")
    obj(60, "<< /Type /Outlines /First 61 0 R /Last 62 0 R /Count 2 >>")
    obj(61, "<< /Title (Form) /Parent 60 0 R /Next 62 0 R /Dest [3 0 R /XYZ 0 792 0] >>")
    obj(62, "<< /Title (Page two) /Parent 60 0 R /Prev 61 0 R /Dest [4 0 R /XYZ 0 792 0] >>")
    return classic_pdf(objs, root=1, info=10)


def main():
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, build in (("acroform-xrefstream.pdf", acroform_xrefstream),
                        ("acroform-fieldkinds.pdf", acroform_fieldkinds)):
        path = out_dir / name
        path.write_bytes(build())
        print(f"{path.name}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
