# Build an HTML dashboard showing coded interview excerpts in context:
# left pane = transcript with inline highlights, right pane = code -> supporting
# passage table (one section per transcript). Reads the LLM coding pilot output.
#
# Inputs:  data/raw/interview-transcripts/*.docx (never committed)
#          data/processed/interview-coding/coded_segments.csv
#          IMCC Codebook v3.docx (repo root, untracked; rendered as the Codebook tab)
# Output:  data/processed/interview-coding/dashboard.html (gitignored — embeds
#          transcript text; do not commit or share outside the team)
#
# Excerpts in the CSV were lightly edited (ellipses, [bracketed] notes), so
# passages are located by exact match first, then anchor-word fuzzy match.

library(here)

# Optional arg: path to a coded-segments CSV (default = the pilot). Any CSV with columns
# file, speaker, excerpt, domain, code, confidence, rationale works, e.g. the
# llm_ellmer_*.csv files written by ellmer_coding_example.R. Output name follows input.
csv_path <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(csv_path)) csv_path <- here("data", "processed", "interview-coding", "coded_segments.csv")
raw_dir  <- here("data", "raw", "interview-transcripts")
out_path <- if (basename(csv_path) == "coded_segments.csv")
  here("data", "processed", "interview-coding", "dashboard.html") else
  sub("\\.csv$", "_dashboard.html", csv_path)
codebook_path <- here("IMCC Codebook v3.docx")

seg <- read.csv(csv_path, encoding = "UTF-8")

stems <- sort(unique(seg$file))  # transcripts discovered from the coded CSV

domain_colors <- c(
  "Participant Characteristics" = "#cfe8f3",
  "Care Context"                = "#fff2cf",
  "Supports"                    = "#dcedc8",
  "Challenges"                  = "#fbd5d0",
  "Navigation"                  = "#e6dcf5",
  "Desired Supports"            = "#ffe3c9",
  "Ideal System"                = "#d0f0ef",
  "Outcomes"                    = "#e0f0d8",
  "Solutions"                   = "#f9d9ec",
  "Framing"                     = "#d9e2f3"
)
new_theme_codes <- c("DESIRED_SUPPORT_OTHER", "SOLUTION_OTHER")

# ---- text handling -----------------------------------------------------------

esc <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  gsub(">", "&gt;", x, fixed = TRUE)
}

norm_chars <- function(x) {
  x <- gsub("[‘’‚‛]", "'", x)
  x <- gsub("[“”„]", "'", x)
  x <- gsub('"', "'", x, fixed = TRUE)
  gsub("…", "...", x)
}

read_transcript <- function(stem) {
  docx <- file.path(raw_dir, paste0(stem, ".docx"))
  tmp <- tempfile(fileext = ".txt")
  system2("pandoc", c(shQuote(docx), "-t", "plain", "-o", shQuote(tmp)))
  lines <- readLines(tmp, encoding = "UTF-8", warn = FALSE)
  paras <- character(0); buf <- character(0)
  for (ln in c(lines, "")) {
    if (nzchar(trimws(ln))) buf <- c(buf, trimws(ln))
    else if (length(buf)) { paras <- c(paras, paste(buf, collapse = " ")); buf <- character(0) }
  }
  paste(paras, collapse = "\n\n")
}

# lowercase, quote-normalized, timecodes blanked — same length as original
match_copy <- function(text) {
  m <- tolower(norm_chars(text))
  hits <- gregexpr("\\[[0-9]{2}:[0-9]{2}:[0-9]{2}\\]", m)[[1]]
  if (hits[1] != -1) {
    lens <- attr(hits, "match.length")
    for (i in seq_along(hits)) substr(m, hits[i], hits[i] + lens[i] - 1) <- strrep(" ", lens[i])
  }
  m
}

excerpt_fragments <- function(ex) {
  ex <- norm_chars(ex)
  ex <- gsub("\\[[^]]*\\]", " ... ", ex)  # editorial brackets = split points
  parts <- trimws(strsplit(ex, "\\s*\\.\\.\\.\\s*")[[1]])
  parts[nchar(parts) >= 12]
}

locate_fragment <- function(frag, mtext) {
  f <- tolower(frag); n <- nchar(f); N <- nchar(mtext)
  p <- regexpr(f, mtext, fixed = TRUE)[1]
  if (p > 0) return(c(p, p + n - 1))
  words <- regmatches(f, gregexpr("[a-záéíóúñü']{5,}", f))[[1]]
  words <- head(unique(words[order(-nchar(words))]), 4)
  cand <- integer(0)
  for (w in words) {
    off <- regexpr(w, f, fixed = TRUE)[1]
    hits <- gregexpr(w, mtext, fixed = TRUE)[[1]]
    if (hits[1] > 0) cand <- c(cand, as.vector(hits) - off + 1)
  }
  cand <- unique(pmax(1, pmin(cand, max(1, N - n + 1))))
  starts <- if (length(cand)) {
    unique(unlist(lapply(cand, function(s) max(1, s - 10):min(N - n + 1, s + 10))))
  } else seq(1, max(1, N - n + 1), by = 8)
  wins <- substring(mtext, starts, starts + n - 1)
  d <- utils::adist(f, wins)[1, ]
  b <- which.min(d)
  if (d[b] / n <= 0.4) c(starts[b], starts[b] + n - 1) else NULL
}

# ---- codebook -----------------------------------------------------------------

# The codebook docx is one table per domain (Domain, Parent_Code, Code,
# Definition, Include, Exclude, Keywords), each under a research-question
# heading. pandoc's gfm output makes that a flat pipe-table parse.
read_codebook <- function(path) {
  tmp <- tempfile(fileext = ".md")
  system2("pandoc", c(shQuote(path), "-t", "gfm", "--wrap=none", "-o", shQuote(tmp)))
  lines <- readLines(tmp, encoding = "UTF-8", warn = FALSE)
  question <- NA_character_; rows <- list()
  for (ln in lines) {
    if (startsWith(ln, "# ")) { question <- sub("^# ", "", ln); next }
    if (!startsWith(ln, "|") || grepl("^\\|[-| ]+\\|$", ln) || grepl("**Domain**", ln, fixed = TRUE)) next
    cells <- trimws(strsplit(sub("\\|$", "", sub("^\\|", "", ln)), "|", fixed = TRUE)[[1]])
    if (length(cells) != 7) stop("codebook row with ", length(cells), " cells (expected 7): ", ln)
    cells <- gsub("\\\\([_*])", "\\1", cells)  # undo markdown escapes
    rows[[length(rows) + 1]] <- data.frame(
      question = question, domain = cells[1], parent = cells[2], code = cells[3],
      definition = cells[4], include = cells[5], exclude = cells[6], keywords = cells[7],
      stringsAsFactors = FALSE)
  }
  cb <- do.call(rbind, rows)
  cb$code <- gsub("_+", "_", gsub(" ", "", cb$code))  # docx typos: "CARE_ PRIMARY", "CARE__DAILY"
  cb
}

codebook <- read_codebook(codebook_path)

bad_dom <- setdiff(codebook$domain, names(domain_colors))
if (length(bad_dom)) stop("codebook domain(s) without a color: ", paste(bad_dom, collapse = ", "))
dup <- codebook$code[duplicated(codebook$code)]
if (length(dup)) message("codebook: duplicate code(s): ", paste(unique(dup), collapse = ", "))
uncoded <- setdiff(seg$code, codebook$code)
if (length(uncoded)) message("coded_segments uses code(s) not in codebook: ", paste(uncoded, collapse = ", "))
code_def <- setNames(codebook$definition, paste(codebook$domain, codebook$code))  # code names repeat across domains

# ---- build one transcript section -------------------------------------------

conf_badge <- function(x) sprintf('<span class="conf conf-%s">%s</span>', x, x)

build_section <- function(stem) {
  text  <- read_transcript(stem)
  mtext <- match_copy(text)
  rows  <- seg[seg$file == stem, ]
  rows$rid <- seq_len(nrow(rows))

  intervals <- list(); unmatched <- character(0)
  for (i in seq_len(nrow(rows))) {
    found <- FALSE
    for (frag in excerpt_fragments(rows$excerpt[i])) {
      loc <- locate_fragment(frag, mtext)
      if (!is.null(loc)) { intervals[[length(intervals) + 1]] <- c(loc, rows$rid[i]); found <- TRUE }
    }
    if (!found) unmatched <- c(unmatched, sprintf("%s / %s", rows$code[i], substr(rows$excerpt[i], 1, 60)))
  }
  if (length(unmatched))
    message(stem, ": ", length(unmatched), " excerpt(s) not located:\n  ", paste(unmatched, collapse = "\n  "))

  # split text at all interval breakpoints; tag each piece with covering rows
  iv <- do.call(rbind, intervals)
  bp <- sort(unique(c(1, iv[, 1], iv[, 2] + 1, nchar(text) + 1)))
  html_body <- character(0)
  for (k in seq_len(length(bp) - 1)) {
    s <- bp[k]; e <- bp[k + 1] - 1
    piece <- esc(substring(text, s, e))
    cover <- iv[iv[, 1] <= s & iv[, 2] >= e, 3]
    if (length(cover)) {
      cover <- sort(unique(cover))
      col <- domain_colors[[rows$domain[rows$rid == cover[1]]]]
      codes <- paste(rows$code[rows$rid %in% cover], collapse = ", ")
      piece <- gsub("\n\n", "<br><br>", piece, fixed = TRUE)
      piece <- sprintf('<mark data-rows="%s" style="background:%s" class="%s" title="%s">%s</mark>',
                       paste(cover, collapse = " "), col,
                       if (length(cover) > 1) "multi" else "", esc(codes), piece)
    } else {
      piece <- gsub("\n\n", "</p>\n<p>", piece, fixed = TRUE)
    }
    html_body <- c(html_body, piece)
  }

  code_rows <- character(0)
  for (dom in names(domain_colors)) {
    dr <- rows[rows$domain == dom, ]
    if (!nrow(dr)) next
    code_rows <- c(code_rows, sprintf('<div class="dom-head">%s</div>', esc(dom)))
    for (i in seq_len(nrow(dr))) {
      flag <- if (dr$code[i] %in% new_theme_codes)
        '<span class="newtheme">possible new code</span>' else ""
      code_rows <- c(code_rows, sprintf(
        '<div class="crow" data-row="%d">
           <span class="chip" style="background:%s"></span>
           <div class="crow-main">
             <div class="crow-top"><span class="codename" title="%s">%s</span>%s%s</div>
             <div class="passage">&ldquo;%s&rdquo;</div>
             <div class="rationale">%s</div>
           </div></div>',
        dr$rid[i], domain_colors[[dom]], esc(code_def[paste(dom, dr$code[i])]), esc(dr$code[i]),
        conf_badge(dr$confidence[i]),
        flag, esc(dr$excerpt[i]), esc(dr$rationale[i])))
    }
  }

  sprintf('<section class="tx-section panel" id="sec-%s">
    <h2 class="fname">%s</h2>
    <div class="meta">%d coded segments</div>
    <div class="grid">
      <div class="transcript"><p>%s</p></div>
      <div class="codes"><div class="codes-head"><span>Code</span><span>Supporting passage</span></div>%s</div>
    </div></section>',
    stem, esc(stem), nrow(rows),
    paste(html_body, collapse = ""), paste(code_rows, collapse = "\n"))
}

# ---- page --------------------------------------------------------------------

legend <- paste(sprintf('<span class="lg"><span class="chip" style="background:%s"></span>%s</span>',
                        domain_colors, esc(names(domain_colors))), collapse = " ")

sections <- paste(vapply(stems, build_section, character(1)), collapse = "\n")

# ---- overview tab: code frequencies -----------------------------------------

code_info <- unique(seg[, c("code", "domain")])
counts <- as.data.frame(table(code = seg$code), stringsAsFactors = FALSE)
counts <- merge(counts, code_info, by = "code")
counts <- counts[order(-counts$Freq, counts$code), ]
per_file <- table(seg$code, seg$file)
max_n <- max(counts$Freq)

# row id within each transcript section — same construction as build_section()
seg$rid <- ave(seq_len(nrow(seg)), seg$file, FUN = seq_along)

bar_rows <- vapply(seq_len(nrow(counts)), function(i) {
  cd <- counts$code[i]; n <- counts$Freq[i]
  pf <- per_file[cd, stems]
  tip <- paste(sprintf("%s: %d", stems[pf > 0], pf[pf > 0]), collapse = "\n")
  ps <- seg[seg$code == cd, ]
  passages <- sprintf(
    '<div class="pitem"><div class="pmeta"><span class="pfile">%s</span> &middot; %s %s
       <button class="goto" data-sec="sec-%s" data-row="%d">open in transcript &rarr;</button></div>
     <div class="passage">&ldquo;%s&rdquo;</div><div class="rationale">%s</div></div>',
    esc(ps$file), esc(ps$speaker), conf_badge(ps$confidence), ps$file, ps$rid,
    esc(ps$excerpt), esc(ps$rationale))
  sprintf('<div class="brow" title="%s" data-code="%s">
     <span class="bcode">%s</span>
     <span class="btrack"><span class="bar" style="width:%.1f%%;background:%s"></span></span>
     <span class="bn">%d</span><span class="bf">%d</span>
   </div><div class="plist">%s</div>', esc(tip), esc(cd), esc(cd), 100 * n / max_n,
    domain_colors[[counts$domain[i]]], n, sum(pf > 0), paste(passages, collapse = "\n"))
}, character(1))

dom_totals <- sort(table(seg$domain), decreasing = TRUE)
dom_cells <- paste(sprintf(
  '<span class="lg"><span class="chip" style="background:%s"></span>%s&nbsp;<b>%d</b></span>',
  domain_colors[names(dom_totals)], esc(names(dom_totals)), as.integer(dom_totals)), collapse = " ")

overview <- sprintf('<section class="tx-section panel" id="sec-overview">
  <h2>Code frequency</h2>
  <div class="meta">%d coded segments across %d transcripts &middot; %d distinct codes &middot; click a code to list all its passages</div>
  <div class="dom-totals">%s</div>
  <div class="bchart">
    <div class="brow bhead"><span class="bcode"></span><span class="btrack"></span>
      <span class="bn">All</span><span class="bf" title="Number of transcripts the code appears in; hover a row for per-file counts">Txs</span></div>
    %s
  </div></section>',
  nrow(seg), length(stems), nrow(counts), dom_cells,
  paste(bar_rows, collapse = "\n"))

# ---- codebook tab ------------------------------------------------------------

n_coded <- table(seg$code)
cb_domains <- unique(codebook$domain)  # docx order
cb_blocks <- vapply(cb_domains, function(dom) {
  d <- codebook[codebook$domain == dom, ]
  n <- as.integer(n_coded[d$code]); n[is.na(n)] <- 0L
  trs <- sprintf('<tr data-domain="%s"><td class="cb-code">%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class="cb-kw">%s</td><td class="cb-n">%s</td></tr>',
    esc(dom), esc(d$code), esc(d$parent), esc(d$definition), esc(d$include), esc(d$exclude),
    esc(d$keywords), ifelse(n > 0, sprintf('<a class="cb-goto" data-code="%s" title="List all passages">%d</a>', esc(d$code), n), ""))
  sprintf('<div class="cb-dom" id="cb-%s">
    <div class="cb-dom-head"><span class="chip" style="background:%s"></span>%s
      <span class="cb-q">%s</span></div>
    <table class="cb"><thead><tr><th>Code</th><th>Parent</th><th>Definition</th><th>Include</th>
      <th>Exclude</th><th>Keywords</th><th class="cb-n" title="Segments assigned this code in the pilot">n</th></tr></thead>
    <tbody>%s</tbody></table></div>',
    gsub("[^a-z]", "", tolower(dom)), domain_colors[[dom]], esc(dom), esc(d$question[1]),
    paste(trs, collapse = "\n"))
}, character(1))

codebook_tab <- sprintf('<section class="tx-section panel" id="sec-codebook">
  <h2>Codebook</h2>
  <div class="meta">IMCC Codebook v3 &middot; %d codes across %d domains &middot; n = segments assigned the code in the pilot</div>
  <input id="cbsearch" type="search" placeholder="Filter codes, definitions, keywords&hellip;" autocomplete="off">
  %s</section>', nrow(codebook), length(cb_domains), paste(cb_blocks, collapse = "\n"))

tabs <- paste(c('<button class="tab active" data-target="sec-overview">Overview</button>',
  '<button class="tab" data-target="sec-codebook">Codebook</button>',
  '<select id="txsel"><option value="">Select a transcript&hellip;</option>',
  sprintf('<option value="sec-%s">%s</option>', stems, esc(stems)),
  '</select>'), collapse = "\n")

# sprintf caps the format string at 8192 bytes, so the page is two pieces
page <- paste0(sprintf('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>1MCC — Coded interview transcripts (LLM pilot)</title>
<style>
  :root { --navy:#0a2240; --orange:#e0592a; }
  body { margin:0; font-family:-apple-system,"Segoe UI",Helvetica,Arial,sans-serif; color:#1b1b1b; background:#fafafa; }
  header { padding:28px 40px 18px; border-bottom:4px solid var(--orange); background:#fff; }
  h1 { color:var(--navy); margin:0 0 6px; font-size:26px; }
  .sub { color:#555; font-size:13px; }
  .legend { padding:10px 40px; font-size:12px; background:#fff; border-bottom:1px solid #e4e4e4; }
  .lg { margin-right:14px; white-space:nowrap; }
  .chip { display:inline-block; width:11px; height:11px; border-radius:2px; margin-right:5px; vertical-align:-1px; border:1px solid rgba(0,0,0,.15); }
  .tx-section { padding:26px 40px 10px; }
  h2 { color:var(--navy); font-size:19px; margin:0 0 2px; }
  .meta { color:#777; font-size:12px; margin-bottom:12px; font-family:ui-monospace,Menlo,monospace; }
  .grid { display:grid; grid-template-columns: 1fr 1fr; gap:26px; }
  .transcript { background:#fff; border:1px solid #e2e2e2; border-radius:6px; padding:20px 24px;
                max-height:78vh; overflow-y:auto; font-family:Georgia,serif; font-size:15px; line-height:1.65; }
  .transcript p { margin:0 0 .9em; }
  mark { padding:1px 2px; border-radius:2px; cursor:pointer; }
  mark.multi { border-bottom:2px dotted var(--orange); }
  mark.active { outline:2px solid var(--navy); }
  .codes { max-height:78vh; overflow-y:auto; }
  .codes-head { display:grid; grid-template-columns:auto 1fr; gap:10px; font-size:11px; letter-spacing:.08em;
                color:#888; text-transform:uppercase; border-bottom:3px solid var(--navy); padding-bottom:6px; margin-bottom:4px; }
  .dom-head { font-size:11px; letter-spacing:.06em; text-transform:uppercase; color:var(--navy);
              font-weight:700; margin:14px 0 4px; }
  .crow { display:flex; gap:10px; padding:9px 8px; border-bottom:1px solid #ececec; cursor:pointer; border-radius:4px; }
  .crow:hover { background:#f0f4f8; }
  .crow.sel { background:#e8eef6; outline:1px solid #b9c9dd; }
  .codename { font-family:ui-monospace,Menlo,monospace; font-weight:700; font-size:12.5px; color:var(--navy); margin-right:8px; }
  .passage { font-family:Georgia,serif; font-size:13px; color:#333; margin-top:3px; }
  .rationale { font-size:11.5px; color:#888; margin-top:2px; }
  .conf { font-size:10px; padding:1px 6px; border-radius:8px; margin-right:6px; vertical-align:1px; }
  .conf-high { background:#e0f0d8; color:#2d5a27; } .conf-medium { background:#fff2cf; color:#7a5c00; }
  .conf-low { background:#eee; color:#666; }
  .newtheme { font-size:10px; background:var(--orange); color:#fff; padding:1px 6px; border-radius:2px;
              letter-spacing:.04em; text-transform:uppercase; }
  .tabs { display:flex; gap:6px; padding:14px 40px 0; background:#fff; border-bottom:1px solid #e4e4e4; }
  .tab { border:1px solid #ddd; border-bottom:none; background:#f3f3f3; padding:8px 16px; font-size:13px;
         cursor:pointer; border-radius:6px 6px 0 0; color:#444; font-family:inherit; }
  .tab.active { background:#fff; color:var(--navy); font-weight:700; position:relative; top:1px; }
  .panel { display:none; } .panel.active { display:block; }
  .dom-totals { font-size:12px; margin:6px 0 18px; }
  .bchart { max-width:900px; }
  .brow { display:grid; grid-template-columns: 290px 1fr 44px 40px; gap:8px;
          align-items:center; padding:2.5px 0; font-size:12.5px; }
  .fname { font-family:ui-monospace,Menlo,monospace; font-size:16px; }
  #txsel { font-family:ui-monospace,Menlo,monospace; font-size:12.5px; padding:7px 10px;
           border:1px solid #ddd; border-radius:6px 6px 0 0; background:#f3f3f3; color:#444; cursor:pointer; }
  #txsel.active { background:#fff; color:var(--navy); font-weight:700; }
  .bhead { color:#888; font-size:10.5px; letter-spacing:.07em; text-transform:uppercase;
           border-bottom:2px solid var(--navy); padding-bottom:4px; margin-bottom:4px; }
  .bcode { font-family:ui-monospace,Menlo,monospace; font-weight:600; color:var(--navy);
           text-align:right; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .btrack { background:#f0f0f0; border-radius:3px; height:14px; }
  .bar { display:block; height:100%%; border-radius:3px; border-right:1px solid rgba(0,0,0,.18); }
  .bn { font-weight:700; text-align:right; } .bf { color:#999; text-align:right; }
  footer { padding:20px 40px 34px; font-size:12px; color:#777; }
  #cbsearch { width:360px; max-width:100%%; padding:7px 10px; font:inherit; font-size:13px;
              border:1px solid #ccc; border-radius:6px; margin:4px 0 18px; }
  .cb-dom { margin-bottom:28px; }
  .cb-dom-head { font-size:13px; font-weight:700; color:var(--navy); text-transform:uppercase;
                 letter-spacing:.05em; display:flex; align-items:center; gap:8px; margin-bottom:6px; }
  .cb-q { font-weight:400; text-transform:none; letter-spacing:0; color:#666; font-style:italic; }
  table.cb { border-collapse:collapse; width:100%%; font-size:12.5px; }
  table.cb th { text-align:left; font-size:10.5px; letter-spacing:.07em; text-transform:uppercase; color:#888;
                border-bottom:2px solid var(--navy); padding:4px 8px 4px 0; }
  table.cb td { vertical-align:top; padding:6px 8px 6px 0; border-bottom:1px solid #ececec; }
  .cb-code { font-family:ui-monospace,Menlo,monospace; font-weight:600; color:var(--navy); white-space:nowrap; }
  .cb-kw { color:#777; font-size:12px; }
  .cb-n { text-align:right; font-weight:700; width:30px; }
  .cb-dom.hidden, tr.hidden { display:none; }
  .brow[data-code] { cursor:pointer; border-radius:4px; }
  .brow[data-code]:hover, .brow.open { background:#f0f4f8; }
  .plist { display:none; margin:2px 0 10px 290px; padding:6px 12px; border-left:3px solid #d8dfe8; }
  .plist.open { display:block; }
  .pitem { padding:7px 0; border-bottom:1px solid #ececec; }
  .pmeta { font-size:11px; color:#888; }
  .pfile { font-family:ui-monospace,Menlo,monospace; color:var(--navy); }
  .goto { font:inherit; font-size:11px; color:var(--navy); background:none; border:none;
          cursor:pointer; text-decoration:underline; padding:0; margin-left:6px; }
  .cb-goto { color:var(--navy); cursor:pointer; text-decoration:underline dotted; }
</style></head><body>
<header><h1>Coded interview transcripts — LLM pilot, IMCC Codebook v3</h1>
<div class="sub">Click a code row to jump to its passage; click a highlight to see its codes (dotted underline = multiple codes overlap).</div></header>
<nav class="tabs">%s</nav>
<div class="legend">%s</div>
%s
%s
%s
<footer>Generated by scripts/nlp/coding_dashboard.R from coded_segments.csv.</footer>
', tabs, legend, overview, codebook_tab, sections), '<script>
document.querySelectorAll(".tx-section").forEach(sec => {
  const marks = [...sec.querySelectorAll("mark")], rows = [...sec.querySelectorAll(".crow")];
  const clear = () => { marks.forEach(m => m.classList.remove("active")); rows.forEach(r => r.classList.remove("sel")); };
  rows.forEach(r => r.addEventListener("click", () => {
    clear(); r.classList.add("sel");
    const ms = marks.filter(m => m.dataset.rows.split(" ").includes(r.dataset.row));
    ms.forEach(m => m.classList.add("active"));
    if (ms[0]) ms[0].scrollIntoView({behavior:"smooth", block:"center"});
  }));
  marks.forEach(m => m.addEventListener("click", () => {
    clear(); m.classList.add("active");
    const ids = m.dataset.rows.split(" ");
    const rs = rows.filter(r => ids.includes(r.dataset.row));
    rs.forEach(r => r.classList.add("sel"));
    if (rs[0]) rs[0].scrollIntoView({behavior:"smooth", block:"center"});
  }));
});
const panels = [...document.querySelectorAll(".panel")];
const tabBtns = [...document.querySelectorAll(".tab")], sel = document.getElementById("txsel");
const show = id => panels.forEach(p => p.classList.toggle("active", p.id === id));
tabBtns.forEach(b => b.addEventListener("click", () => {
  show(b.dataset.target); tabBtns.forEach(x => x.classList.toggle("active", x === b));
  sel.classList.remove("active"); sel.value = "";
}));
sel.addEventListener("change", () => {
  if (!sel.value) return;
  show(sel.value); sel.classList.add("active"); tabBtns.forEach(x => x.classList.remove("active"));
});
show("sec-overview");
// Overview: click a code row to list every passage assigned that code
document.querySelectorAll(".brow[data-code]").forEach(r => r.addEventListener("click", () => {
  r.classList.toggle("open"); r.nextElementSibling.classList.toggle("open");
}));
document.querySelectorAll(".goto").forEach(b => b.addEventListener("click", e => {
  e.stopPropagation();
  show(b.dataset.sec); sel.value = b.dataset.sec; sel.classList.add("active");
  tabBtns.forEach(x => x.classList.remove("active"));
  const crow = document.querySelector(`#${b.dataset.sec} .crow[data-row="${b.dataset.row}"]`);
  crow.click(); crow.scrollIntoView({block:"center"});
}));
document.querySelectorAll(".cb-goto").forEach(a => a.addEventListener("click", () => {
  const row = document.querySelector(`.brow[data-code="${a.dataset.code}"]`);
  if (!row) return;
  tabBtns[0].click();
  if (!row.classList.contains("open")) row.click();
  row.scrollIntoView({behavior:"smooth", block:"start"});
}));
document.getElementById("cbsearch").addEventListener("input", e => {
  const q = e.target.value.trim().toLowerCase();
  document.querySelectorAll(".cb-dom").forEach(d => {
    let any = false;
    d.querySelectorAll("tbody tr").forEach(tr => {
      const hit = !q || tr.textContent.toLowerCase().includes(q);
      tr.classList.toggle("hidden", !hit); any = any || hit;
    });
    d.classList.toggle("hidden", !any);
  });
});
</script></body></html>')

writeLines(page, out_path, useBytes = FALSE)
cat("Wrote", out_path, "\n")
