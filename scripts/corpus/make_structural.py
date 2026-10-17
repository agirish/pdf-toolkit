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


def main():
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "acroform-xrefstream.pdf"
    path.write_bytes(acroform_xrefstream())
    print(f"{path.name}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
