#!/usr/bin/env bash
# Print each page of the rendered site to a PDF, for sharing single pages
# (e.g. with CAG) without pointing people at the whole website.
#
# Usage: scripts/99_export-pdfs.sh          # after `quarto render` at the root
# Output: exports/pdf/<page>.pdf (gitignored)
#
# Uses headless Chrome against a local web server so the interactive tables
# and charts render as they do in the browser. Paged tables print only the
# page currently shown (the first five rows); the state table and dictionary
# are the main ones affected.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME" >&2; exit 1; }
[ -f docs/index.html ] || { echo "docs/ is empty; run 'quarto render' first" >&2; exit 1; }

mkdir -p exports/pdf
PORT=8771
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory docs > /dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

print_page() { # <relative html path> <pdf name>
  "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --virtual-time-budget=8000 \
    --print-to-pdf="exports/pdf/$2.pdf" "http://127.0.0.1:$PORT/$1" 2>/dev/null
  echo "  exports/pdf/$2.pdf"
}

echo "Printing site pages to PDF:"
print_page index.html                              1mcc-home
print_page scripts/01_clean-data.html              1mcc-cleaning
print_page scripts/survey/01_chartbook.html        1mcc-chartbook
print_page variables.html                          1mcc-variables
print_page deliveries.html                         1mcc-deliveries
print_page coding-dashboard/index.html             1mcc-coding-dashboard
