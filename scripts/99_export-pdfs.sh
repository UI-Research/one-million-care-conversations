#!/usr/bin/env bash
# Print each page of the rendered site to a PDF, for sharing single pages
# (e.g. with CAG) without pointing people at the whole website.
#
# Usage: scripts/99_export-pdfs.sh                      # after `quarto render` at the root
#        scripts/99_export-pdfs.sh path/to/dashboard.html  # print the tabs of that coding
#                                                        # dashboard instead (e.g. a run's)
#        DASHBOARD_TRANSCRIPT=idv-lf DASHBOARD_QUESTION=q7 scripts/99_export-pdfs.sh  # choose the examples
# Output: exports/pdf/<page>.pdf (gitignored)
#
# Uses headless Chrome against a local web server so the interactive tables
# and charts render as they do in the browser. Paged tables print only the
# page currently shown (the first five rows); the state table and dictionary
# are the main ones affected.
#
# The coding dashboard is one page with tabs, so besides the page as it opens
# (the overview, 1mcc-coding-dashboard.pdf) the tabs worth sharing go into one
# more PDF, 1mcc-coding-tabs.pdf: the Codebook tab, one transcript as an
# example of the coded view (the first in the dropdown, or the one named by
# DASHBOARD_TRANSCRIPT=<part of its file name>), and, from the companion
# open-ended.html page next to it, the code-frequency tab and one example
# question's answers (DASHBOARD_QUESTION, default canvass_q3). A print
# stylesheet is added to a temporary copy of the page so the chosen tab is the
# only one shown, the two scrolling columns of a transcript tab expand to full
# length, and the transcript comes first with its code table after it.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME" >&2; exit 1; }
[ -f docs/index.html ] || { echo "docs/ is empty; run 'quarto render' first" >&2; exit 1; }

mkdir -p exports/pdf
PORT=8771
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory docs > /dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null' EXIT
sleep 1

print_page() { # <relative html path> <pdf name>
  "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --virtual-time-budget=8000 \
    --print-to-pdf="exports/pdf/$2.pdf" "http://127.0.0.1:$PORT/$1" 2>/dev/null
  echo "  exports/pdf/$2.pdf"
}

DASHBOARD="${1:-docs/coding-dashboard/index.html}"
[ -f "$DASHBOARD" ] || { echo "dashboard not found: $DASHBOARD" >&2; exit 1; }

# <dashboard html> <pdf name prefix>: one PDF for the Codebook tab, one per transcript
print_dashboard_tabs() {
  mkdir -p docs/_print
  trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf docs/_print' EXIT
  local oe="$(dirname "$1")/open-ended.html"
  python3 - "$1" "$oe" docs/_print <<'PY'
import sys, os
extra = """
<style>@media print {
  .tabs, #txsel, #cbsearch, .legend { display:none !important; }
  .panel:not(.print), #sec-unused:not(.print), .plist { display:none !important; }
  .panel.print { display:block !important; }
  .grid { display:block !important; }
  .transcript, .codes { max-height:none !important; overflow:visible !important; }
  .codes { margin-top:24px; }
  .crow, .cb-dom, .pitem { break-inside:avoid; }
  body { background:#fff; }
}</style>
<script>(function () {
  var id = location.hash.slice(1); if (!id) return;
  document.querySelectorAll(".panel").forEach(function (p) {
    p.classList.toggle("print", p.id === id); p.classList.toggle("active", p.id === id);
  });
  var u = document.getElementById("sec-unused"); if (u) u.classList.toggle("print", id === "sec-codebook");
})();</script>
</body>"""
for src, name in [(sys.argv[1], "dashboard.html"), (sys.argv[2], "open-ended.html")]:
    if os.path.exists(src):
        html = open(src, encoding="utf-8").read()
        open(os.path.join(sys.argv[3], name), "w", encoding="utf-8").write(html.replace("</body>", extra, 1))
PY
  # the Codebook tab and one example transcript from the transcripts page, the open-ended
  # tab (with one example question) from the companion page, merged into one PDF
  ids=$(python3 - "$1" "$oe" "${DASHBOARD_TRANSCRIPT:-}" "${DASHBOARD_QUESTION:-canvass_q3}" <<'PY'
import sys, re, os
html, want, q = open(sys.argv[1], encoding="utf-8").read(), sys.argv[3], sys.argv[4]
stems = [i for i in re.findall(r'<section class="tx-section panel" id="(sec-[^"]+)"', html)
         if i not in ("sec-overview", "sec-open", "sec-codebook")]
pick = next((i for i in stems if want and want in i), stems[0] if stems else None)
ids = ["dashboard.html#sec-codebook"] + (["dashboard.html#" + pick] if pick else [])
if os.path.exists(sys.argv[2]): ids += ["open-ended.html#sec-open", "open-ended.html#sec-q-" + q]
print(" ".join(ids))
PY
  )
  parts=()
  for id in $ids; do
    tmp="exports/pdf/_$(echo "$id" | tr '#' '_').pdf"
    "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --virtual-time-budget=8000 \
      --print-to-pdf="$tmp" "http://127.0.0.1:$PORT/_print/$id" 2>/dev/null
    parts+=("$tmp")
  done
  python3 - "exports/pdf/$2-tabs.pdf" "${parts[@]}" <<'PY'
import sys
from pypdf import PdfWriter
w = PdfWriter()
for f in sys.argv[2:]: w.append(f)
w.write(sys.argv[1])
PY
  rm -f "${parts[@]}"
  echo "  exports/pdf/$2-tabs.pdf  ($ids)"
}

echo "Printing site pages to PDF:"
print_page index.html                              1mcc-home
print_page scripts/01_clean-data.html              1mcc-cleaning
print_page scripts/survey/01_chartbook.html        1mcc-chartbook
print_page variables.html                          1mcc-variables
print_page deliveries.html                         1mcc-deliveries
print_page coding-dashboard/index.html             1mcc-coding-dashboard
print_page coding-dashboard/open-ended.html        1mcc-open-ended-dashboard
echo "Printing coding dashboard tabs from $DASHBOARD:"
print_dashboard_tabs "$DASHBOARD" 1mcc-coding
