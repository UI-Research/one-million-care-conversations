#!/usr/bin/env bash
# Print the pages worth sharing (e.g. with CAG) to PDF, without pointing people at
# the whole website.
#
# Usage: scripts/99_export-pdfs.sh                           # after `quarto render` at the root
#        scripts/99_export-pdfs.sh path/to/run/dashboard.html  # a run's dashboards instead of the published ones
#        DASHBOARD_TRANSCRIPT=idv-lf DASHBOARD_QUESTION=q7 scripts/99_export-pdfs.sh   # choose the examples
# Output (exports/pdf/, gitignored):
#   overview.pdf             the home page
#   chartbook.pdf            the chartbook
#   transcript-coding.pdf    the code frequency tab, then one coded transcript as it looks
#                            on screen (transcript with highlights beside its code table)
#   open-ended-coding.pdf    the questions and code frequency tab, then one question's
#                            answers with their highlights as they look on screen
#
# Headless Chrome prints the pages against a local web server so interactive tables
# and charts render as in the browser; paged tables print only the rows shown. The
# coding dashboards are one page with tabs, so a temporary copy gets a small script
# that opens the tab named in the URL hash (`#show=<id>`) and a print stylesheet that hides the
# other tabs. The "as it looks on screen" pages are screenshots of that copy at a
# fixed window size, turned into a PDF page each.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME" >&2; exit 1; }
[ -f docs/index.html ] || { echo "docs/ is empty; run 'quarto render' first" >&2; exit 1; }
DASHBOARD="${1:-docs/coding-dashboard/index.html}"
[ -f "$DASHBOARD" ] || { echo "dashboard not found: $DASHBOARD" >&2; exit 1; }
OPEN_ENDED="$(dirname "$DASHBOARD")/open-ended.html"

OUT=exports/pdf
mkdir -p "$OUT" docs/_print
PORT=8771
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory docs > /dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null || true; rm -rf docs/_print "$OUT"/_*' EXIT
sleep 1

chrome() { "$CHROME" --headless=new --disable-gpu --hide-scrollbars "$@" 2>/dev/null; }

print_page() { # <path under docs/> <output pdf>
  chrome --no-pdf-header-footer --virtual-time-budget=8000 --print-to-pdf="$2" "http://127.0.0.1:$PORT/$1"
}

screenshot_pdf() { # <path under docs/> <output pdf>: one landscape page with the screen view
  chrome --window-size=1600,1100 --force-device-scale-factor=2 --virtual-time-budget=8000 \
    --screenshot="$OUT/_shot.png" "http://127.0.0.1:$PORT/$1"
  python3 -c "
from PIL import Image; im = Image.open('$OUT/_shot.png').convert('RGB'); im.save('$2', 'PDF', resolution=200)"
}

merge_pdf() { # <output> <inputs...>
  python3 - "$@" <<'PY'
import sys
from pypdf import PdfWriter
w = PdfWriter()
for f in sys.argv[2:]: w.append(f)
w.write(sys.argv[1])
PY
}

# Temporary copies of the dashboards: the URL hash picks the tab (and the dropdown
# entry) to show; in print the other tabs are hidden.
python3 - "$DASHBOARD" "$OPEN_ENDED" docs/_print <<'PY'
import sys, os
extra = """
<style>@media print {
  .tabs, #txsel, #cbsearch, .legend, .plist { display:none !important; }
  .panel:not(.print) { display:none !important; }
  .panel.print { display:block !important; }
  .crow, .cb-dom, .pitem, table.qlist tr { break-inside:avoid; }
  body { background:#fff; }
}</style>
<script>(function () {
  // #show=<section id>: not an element id, so the browser does not scroll to it
  var m = location.hash.match(/^#show=(.+)$/); if (!m) return; var id = m[1];
  document.querySelectorAll(".panel").forEach(function (p) {
    p.classList.toggle("print", p.id === id); p.classList.toggle("active", p.id === id);
  });
  var sel = document.getElementById("txsel"), isTab = false;
  document.querySelectorAll(".tab").forEach(function (b) { if (b.dataset.target === id) isTab = true; b.classList.toggle("active", b.dataset.target === id); });
  if (sel && !isTab) { sel.value = id; sel.classList.add("active"); }
  // a transcript pane opens on its first highlighted passage, not the header lines
  var sec = document.getElementById(id), pane = sec && sec.querySelector(".transcript"), mark = pane && pane.querySelector("mark");
  if (mark) pane.scrollTop = mark.getBoundingClientRect().top - pane.getBoundingClientRect().top - 24;
})();</script>
</body>"""
for src, name in [(sys.argv[1], "dashboard.html"), (sys.argv[2], "open-ended.html")]:
    if os.path.exists(src):
        html = open(src, encoding="utf-8").read()
        open(os.path.join(sys.argv[3], name), "w", encoding="utf-8").write(html.replace("</body>", extra, 1))
PY

# the example transcript (first in the dropdown unless DASHBOARD_TRANSCRIPT names one)
TRANSCRIPT=$(python3 - "$DASHBOARD" "${DASHBOARD_TRANSCRIPT:-}" <<'PY'
import sys, re
html, want = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
stems = [i for i in re.findall(r'<section class="tx-section panel" id="(sec-[^"]+)"', html)
         if i not in ("sec-overview", "sec-codebook")]
print(next((i for i in stems if want and want in i), stems[0] if stems else ""))
PY
)
QUESTION="sec-q-${DASHBOARD_QUESTION:-canvass_q3}"

echo "Writing PDFs to $OUT/:"
print_page index.html                        "$OUT/overview.pdf";  echo "  overview.pdf"
print_page scripts/survey/01_chartbook.html  "$OUT/chartbook.pdf"; echo "  chartbook.pdf"

print_page "_print/dashboard.html#show=sec-overview" "$OUT/_tc1.pdf"
screenshot_pdf "_print/dashboard.html#show=$TRANSCRIPT" "$OUT/_tc2.pdf"
merge_pdf "$OUT/transcript-coding.pdf" "$OUT/_tc1.pdf" "$OUT/_tc2.pdf"
echo "  transcript-coding.pdf  (code frequency; screen view of $TRANSCRIPT)"

if [ -f "$OPEN_ENDED" ]; then
  print_page "_print/open-ended.html#show=sec-open" "$OUT/_oe1.pdf"
  screenshot_pdf "_print/open-ended.html#show=$QUESTION" "$OUT/_oe2.pdf"
  merge_pdf "$OUT/open-ended-coding.pdf" "$OUT/_oe1.pdf" "$OUT/_oe2.pdf"
  echo "  open-ended-coding.pdf  (questions and code frequency; screen view of $QUESTION)"
fi
