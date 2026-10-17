#!/bin/bash
#
# Regenerates the real-PDF corpus checked in under
# Tests/PDFToolkitCoreTests/Corpus/.
#
# The corpus is COMMITTED, not built during `swift test` — CI must not depend on
# Chrome being installed, and a fixture that is regenerated on every run can
# drift silently under it. Run this only to add a file or deliberately refresh
# one, then commit the result and re-read docs/testing-corpus.md.
#
# Usage: scripts/corpus/generate.sh [output-dir]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="${1:-$repo_root/Tests/PDFToolkitCoreTests/Corpus}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$out_dir"
echo "corpus -> $out_dir"

# 1. Byte-authored structure (xref stream + object stream + real /AcroForm).
python3 "$repo_root/scripts/corpus/make_structural.py" "$out_dir"

# 2. Quartz/PDFKit-rendered content and real encryption. Compiled rather than run
#    through `swift file.swift` — the interpreter traps inside AppKit here.
swiftc -O -o "$tmp_dir/make_rendered" "$repo_root/scripts/corpus/make_rendered.swift"
"$tmp_dir/make_rendered" "$out_dir"

# 3. A genuinely foreign producer: Chrome's Skia PDF backend, with embedded
#    subset fonts and real link annotations — nothing Apple's writer emits.
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ -x "$chrome" ]]; then
    cp "$repo_root/scripts/corpus/article.html" "$tmp_dir/article.html"
    "$chrome" --headless --disable-gpu --no-pdf-header-footer \
        --print-to-pdf="$out_dir/chrome-article.pdf" \
        "file://$tmp_dir/article.html" 2>/dev/null
    echo "chrome-article.pdf: $(stat -f%z "$out_dir/chrome-article.pdf") bytes"
else
    echo "SKIPPED chrome-article.pdf — Google Chrome not installed."
    echo "  The committed copy is left in place; install Chrome to refresh it."
fi

echo "done. Commit the corpus and keep docs/testing-corpus.md in step."
