# Build an HTML dashboard of one LLM coding run: code frequencies, the codebook,
# each transcript with inline highlights beside its code -> passage table, and the
# open-ended survey/canvassing/poll answers with code counts by tool and the answers
# themselves with their excerpts highlighted.
#
# Inputs:  data/processed/llm-coding/<run_id>/  (written by 02_code-text.py)
#            coded_transcripts.csv, coded_open_ended.csv, manifest.json
#          data/processed/llm-coding/segments.csv   transcript unit table
#          data/processed/open_ended.csv            answer texts (01_open-ended.R)
#          data/processed/codebook.csv              the codebook the run used (00_ingest-codebook.R)
#          data/raw/interview-transcripts/*.docx    transcript text (pandoc)
# Output:  data/processed/llm-coding/<run_id>/dashboard.html (transcripts + Codebook
#          tabs) and open-ended.html (open-ended answers + Codebook tabs), gitignored.
#          Both embed text from PII-skimmed deliveries; they are copied into
#          coding-dashboard/ (the committed, published site resource, as index.html
#          and open-ended.html) only when the second argument is `site`, so
#          publishing a run stays a deliberate step.
#
# Usage:   Rscript scripts/nlp/coding_dashboard.R                  # newest full run
#          Rscript scripts/nlp/coding_dashboard.R 20261006_claude-sonnet-5_medium
#          Rscript scripts/nlp/coding_dashboard.R <run_id> site    # also write coding-dashboard/{index,open-ended}.html
#
# Excerpts are located by exact match first, then anchor-word fuzzy match.

library(here)
library(jsonlite)
`%||%` <- function(a, b) if (is.null(a)) b else a

args <- commandArgs(trailingOnly = TRUE)
runs_root <- here("data", "processed", "llm-coding")
run_dirs <- list.dirs(runs_root, recursive = FALSE)
run_dirs <- run_dirs[file.exists(file.path(run_dirs, "manifest.json"))]
run_dirs <- run_dirs[vapply(run_dirs, \(d) is.null(fromJSON(file.path(d, "manifest.json"))$limit), logical(1))]
run_dir <- if (!is.na(args[1])) file.path(runs_root, args[1]) else run_dirs[which.max(file.mtime(run_dirs))]
if (!dir.exists(run_dir)) stop("run folder not found: ", run_dir)
manifest <- fromJSON(file.path(run_dir, "manifest.json"))
to_site  <- identical(args[2], "site")

raw_dir  <- here("data", "raw", "interview-transcripts")
codebook_path <- here("data", "processed", "codebook.csv")

seg <- read.csv(file.path(run_dir, "coded_transcripts.csv"), encoding = "UTF-8", stringsAsFactors = FALSE)
seg <- seg[!is.na(seg$code) & nzchar(seg$code), ]
seg$domain[is.na(seg$domain) | !nzchar(seg$domain)] <- "Not in codebook"

oe_codes <- read.csv(file.path(run_dir, "coded_open_ended.csv"), encoding = "UTF-8", stringsAsFactors = FALSE)
answers  <- read.csv(here("data", "processed", "open_ended.csv"), encoding = "UTF-8", stringsAsFactors = FALSE)
answers  <- answers[answers$answer_id %in% oe_codes$answer_id, ]
oe_codes$domain[!is.na(oe_codes$code) & nzchar(oe_codes$code) & (is.na(oe_codes$domain) | !nzchar(oe_codes$domain))] <- "Not in codebook"
oe_assign <- oe_codes[!is.na(oe_codes$code) & nzchar(oe_codes$code), ]   # one row per answer x code

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
  "Framing"                     = "#d9e2f3",
  "Not in codebook"             = "#e0e0e0"
)
is_new_theme <- function(code) grepl("_OTHER$", code)

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
  files <- list.files(raw_dir, pattern = "\\.docx$", full.names = TRUE)
  docx <- files[trimws(sub("\\.docx$", "", basename(files))) == stem][1]
  if (is.na(docx)) stop("no transcript file for ", stem)
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
  parts[nchar(parts) >= 7]
}

# exact match first; fuzzy only for fragments long enough to make a near-miss meaningful
locate_fragment <- function(frag, mtext) {
  f <- tolower(frag); n <- nchar(f); N <- nchar(mtext)
  p <- regexpr(f, mtext, fixed = TRUE)[1]
  if (p > 0) return(c(p, p + n - 1))
  if (n < 12) return(NULL)
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
  # pandoc may not be on the PATH outside RStudio; Quarto bundles one
  pandoc <- if (nzchar(Sys.which("pandoc"))) "pandoc" else "quarto"
  args <- c(if (pandoc == "quarto") "pandoc", shQuote(path), "-t", "gfm", "--wrap=none", "-o", shQuote(tmp))
  status <- system2(pandoc, args)
  if (status != 0 || !file.exists(tmp)) stop("could not convert the codebook docx with pandoc (install pandoc or quarto)")
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

codebook <- read.csv(codebook_path, encoding = "UTF-8", stringsAsFactors = FALSE)
if (!"question" %in% names(codebook)) codebook$question <- ""
cb_version <- if ("version" %in% names(codebook)) codebook$version[1] else "?"

bad_dom <- setdiff(c(codebook$domain, seg$domain, oe_assign$domain), names(domain_colors))
if (length(bad_dom)) stop("codebook domain(s) without a color: ", paste(bad_dom, collapse = ", "))
dup <- codebook$code[duplicated(codebook$code)]
if (length(dup)) message("codebook: duplicate code(s): ", paste(unique(dup), collapse = ", "))
uncoded <- setdiff(c(seg$code, oe_assign$code), codebook$code)
if (length(uncoded)) message("run uses code(s) not in codebook: ", paste(uncoded, collapse = ", "))
code_def <- setNames(codebook$definition, paste(codebook$domain, codebook$code))
code_def[paste("Not in codebook", uncoded)] <- "not a codebook code"

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
      flag <- if (is_new_theme(dr$code[i]))
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
  <h2>Transcripts: code frequency</h2>
  <div class="meta">%d coded segments across %d transcripts &middot; %d distinct codes &middot; click a code to list all its passages</div>
  <div class="dom-totals">%s</div>
  <div class="bchart">
    <div class="brow bhead"><span class="bcode"></span><span class="btrack"></span>
      <span class="bn">All</span><span class="bf" title="Number of transcripts the code appears in; hover a row for per-file counts">Txs</span></div>
    %s
  </div></section>',
  nrow(seg), length(stems), nrow(counts), dom_cells,
  paste(bar_rows, collapse = "\n"))

# ---- open-ended answers tab ------------------------------------------------------

tool_label <- c("survey" = "Survey", "canvassing" = "Canvass", "pre-launch poll" = "Poll")
answers$tool_lab <- tool_label[answers$tool]
answers$aid <- seq_len(nrow(answers))                       # DOM id: a row index, never the respondent id
answers$pathway[is.na(answers$pathway) | !nzchar(answers$pathway)] <- "unknown"
oe_assign <- merge(oe_assign, answers[, c("answer_id", "aid", "tool_lab", "question_text", "pathway", "text")], by = "answer_id")
oe_assign <- oe_assign[order(oe_assign$aid), ]
oe_assign$rid <- seq_len(nrow(oe_assign))

# mark every excerpt inside its answer; returns the answer html with <mark> tags
mark_answer <- function(text, rows) {
  mtext <- match_copy(text)
  intervals <- list()
  for (i in seq_len(nrow(rows))) for (frag in excerpt_fragments(rows$excerpt[i])) {
    loc <- locate_fragment(frag, mtext)
    if (!is.null(loc)) intervals[[length(intervals) + 1]] <- c(loc, rows$rid[i])
  }
  if (!length(intervals)) return(esc(text))
  iv <- do.call(rbind, intervals)
  bp <- sort(unique(c(1, iv[, 1], iv[, 2] + 1, nchar(text) + 1)))
  out <- character(0)
  for (k in seq_len(length(bp) - 1)) {
    a <- bp[k]; b <- bp[k + 1] - 1
    piece <- esc(substring(text, a, b))
    cover <- sort(unique(iv[iv[, 1] <= a & iv[, 2] >= b, 3]))
    if (length(cover)) {
      col <- domain_colors[[rows$domain[rows$rid == cover[1]]]]
      piece <- sprintf('<mark style="background:%s" class="%s" title="%s">%s</mark>', col,
                       if (length(cover) > 1) "multi" else "", esc(paste(rows$code[rows$rid %in% cover], collapse = ", ")), piece)
    }
    out <- c(out, piece)
  }
  paste(out, collapse = "")
}

answer_cards <- vapply(answers$aid, function(a) {
  rows <- oe_assign[oe_assign$aid == a, ]
  ans  <- answers[answers$aid == a, ]
  chips <- if (nrow(rows)) paste(sprintf('<span class="achip" style="background:%s" title="%s">%s</span>%s',
      domain_colors[rows$domain], esc(rows$rationale), esc(rows$code), conf_badge(rows$confidence)), collapse = " ") else '<span class="nocode">no code</span>'
  sprintf('<div class="acard" id="ans-%d" data-q="%s"><div class="ameta">%s &middot; %s &middot; pathway: %s</div>
    <div class="atext">%s</div><div class="achips">%s</div></div>',
    a, esc(ans$question), esc(ans$tool_lab), esc(ans$question), esc(ans$pathway),
    mark_answer(ans$text, rows), chips)
}, character(1))

questions <- unique(answers[, c("tool", "question", "question_order", "question_text", "question_lead")])
questions <- questions[order(questions$question_order), ]
q_counts  <- table(answers$question)
q_coded   <- table(answers$question[answers$aid %in% oe_assign$aid])
q_n       <- as.integer(q_counts[questions$question])
q_nc      <- as.integer(q_coded[questions$question]); q_nc[is.na(q_nc)] <- 0L
q_short   <- c(canvass_q2_hard = "Q2", canvass_q3 = "Q3", poll_change_one_thing = "")
q_label   <- trimws(sprintf("%s %s", tool_label[questions$tool],
                            ifelse(questions$question %in% names(q_short), q_short[questions$question], questions$question)))
short     <- function(x, n = 60) ifelse(nchar(x) > n, paste0(substr(x, 1, n - 1), "\u2026"), x)
q_options <- sprintf('<option value="sec-q-%s">%s: %s (%d)</option>', esc(questions$question),
                     esc(q_label), esc(short(questions$question_text)), q_n)
# the questions in the order asked, with what came before each, linking to its panel
q_table <- sprintf('<table class="qlist"><thead><tr><th>Asked</th><th>Question</th><th>Comes after</th><th class="cb-n">Answers</th><th class="cb-n">With a code</th></tr></thead><tbody>%s</tbody></table>',
  paste(sprintf('<tr><td class="cb-code">%s</td><td><button class="goto-sec" data-sec="sec-q-%s">%s</button></td><td class="cb-kw">%s</td><td class="cb-n">%d</td><td class="cb-n">%d</td></tr>',
                esc(q_label), esc(questions$question), esc(questions$question_text), esc(questions$question_lead), q_n, q_nc), collapse = "\n"))

question_sections <- vapply(seq_len(nrow(questions)), function(i) {
  q <- questions$question[i]
  sprintf('<section class="tx-section panel" id="sec-q-%s">
    <h2 class="fname">%s</h2>
    <div class="qtext">%s</div>
    <div class="meta">%s &middot; %d answers, %d with at least one code &middot; each answer with its excerpts highlighted; hover a highlight for its codes</div>
    <div class="alist">%s</div></section>',
    esc(q), esc(q_label[i]), esc(questions$question_text[i]), esc(questions$question_lead[i]), q_n[i], q_nc[i],
    paste(answer_cards[answers$question == q], collapse = "\n"))
}, character(1))

oe_info   <- unique(oe_assign[, c("code", "domain")])
oe_counts <- as.data.frame(table(code = oe_assign$code), stringsAsFactors = FALSE)
oe_counts <- merge(oe_counts, oe_info, by = "code")
oe_counts <- oe_counts[order(-oe_counts$Freq, oe_counts$code), ]
oe_by_tool <- table(oe_assign$code, oe_assign$tool_lab)
tool_cols <- intersect(c("Survey", "Canvass", "Poll"), colnames(oe_by_tool))
oe_max <- max(oe_counts$Freq)

oe_bar_rows <- vapply(seq_len(nrow(oe_counts)), function(i) {
  cd <- oe_counts$code[i]; n <- oe_counts$Freq[i]
  ps <- oe_assign[oe_assign$code == cd, ]
  passages <- sprintf(
    '<div class="pitem"><div class="pmeta">%s &middot; %s &middot; pathway: %s %s
       <button class="goto-ans" data-ans="%d" data-sec="sec-q-%s">open answer &rarr;</button></div>
     <div class="passage">&ldquo;%s&rdquo;</div><div class="rationale">%s</div></div>',
    esc(ps$tool_lab), esc(ps$question), esc(ps$pathway), conf_badge(ps$confidence), ps$aid, esc(ps$question),
    esc(ps$excerpt), esc(ps$rationale))
  cells <- paste(sprintf('<span class="bf">%d</span>', as.integer(oe_by_tool[cd, tool_cols])), collapse = "")
  sprintf('<div class="brow brow-oe" data-code="%s">
     <span class="bcode">%s</span>
     <span class="btrack"><span class="bar" style="width:%.1f%%;background:%s"></span></span>
     <span class="bn">%d</span>%s
   </div><div class="plist">%s</div>', esc(cd), esc(cd), 100 * n / oe_max,
    domain_colors[[oe_counts$domain[i]]], n, cells, paste(passages, collapse = "\n"))
}, character(1))

oe_dom_totals <- sort(table(oe_assign$domain), decreasing = TRUE)
oe_dom_cells <- paste(sprintf(
  '<span class="lg"><span class="chip" style="background:%s"></span>%s&nbsp;<b>%d</b></span>',
  domain_colors[names(oe_dom_totals)], esc(names(oe_dom_totals)), as.integer(oe_dom_totals)), collapse = " ")
n_coded_answers <- length(unique(oe_assign$aid))
tool_summary <- paste(sprintf("%s %d", tool_label[names(table(answers$tool))], as.integer(table(answers$tool))), collapse = " &middot; ")

open_tab <- sprintf('<section class="tx-section panel" id="sec-open">
  <h2>The questions</h2>
  <div class="meta">In the order the instruments ask them. Click a question to read its answers.</div>
  %s
  <h2 style="margin-top:34px">Code frequency</h2>
  <div class="meta">%d answers (%s) &middot; %d received at least one code &middot; %d code assignments &middot; %d distinct codes &middot; counts are answers assigned each code, not prevalence &middot; click a code to list its passages</div>
  <div class="dom-totals">%s</div>
  <div class="bchart">
    <div class="brow brow-oe bhead"><span class="bcode"></span><span class="btrack"></span>
      <span class="bn">All</span>%s</div>
    %s
  </div></section>',
  q_table, nrow(answers), tool_summary, n_coded_answers, nrow(oe_assign), nrow(oe_counts), oe_dom_cells,
  paste(sprintf('<span class="bf">%s</span>', tool_cols), collapse = ""),
  paste(oe_bar_rows, collapse = "\n"))

# ---- codebook tab ------------------------------------------------------------

n_coded <- table(c(seg$code, oe_assign$code))
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
      <th>Exclude</th><th>Keywords</th><th class="cb-n" title="Transcript segments plus open-ended answers assigned this code in this run">n</th></tr></thead>
    <tbody>%s</tbody></table></div>',
    gsub("[^a-z]", "", tolower(dom)), domain_colors[[dom]], esc(dom), esc(d$question[1]),
    paste(trs, collapse = "\n"))
}, character(1))

# codes in the codebook that no coded segment has used yet, grouped by domain,
# so readers can see what the transcripts have not (yet) covered
code_n <- table(c(paste(seg$domain, seg$code), paste(oe_assign$domain, oe_assign$code)))
unused <- codebook[!(paste(codebook$domain, codebook$code) %in% names(code_n)), ]
unused_blocks <- vapply(cb_domains, function(dom) {
  d <- unused[unused$domain == dom, ]
  if (!nrow(d)) return("")
  sprintf('<p><span class="chip" style="background:%s"></span><strong>%s</strong> (%d): %s</p>',
          domain_colors[[dom]], esc(dom), nrow(d), paste(esc(d$code), collapse = ", "))
}, character(1))
unused_note <- sprintf('<section class="tx-section" id="sec-unused" style="border-top:1px solid #e4e4e4">
  <h2>Codes not yet observed</h2>
  <div class="meta">%d of %d codebook codes were assigned to no transcript segment and no open-ended answer in this run (%d transcripts, %d answers). Absence here is not evidence that the theme is absent from the data.</div>
  %s</section>', nrow(unused), nrow(codebook), length(stems), nrow(answers), paste(unused_blocks[unused_blocks != ""], collapse = "\n"))

codebook_tab <- sprintf('<section class="tx-section panel" id="sec-codebook">
  <h2>Codebook</h2>
  <div class="meta">IMCC Codebook v%s &middot; %d codes across %d domains &middot; n = transcript segments plus answers assigned the code in this run</div>
  <input id="cbsearch" type="search" placeholder="Filter codes, definitions, keywords&hellip;" autocomplete="off">
  %s</section>', cb_version, nrow(codebook), length(cb_domains), paste(cb_blocks, collapse = "\n"))

tabs_tx <- paste(c('<button class="tab active" data-target="sec-overview">Transcripts</button>',
  '<button class="tab" data-target="sec-codebook">Codebook</button>',
  '<select id="txsel"><option value="">Select a transcript&hellip;</option>',
  sprintf('<option value="sec-%s">%s</option>', stems, esc(stems)),
  '</select>'), collapse = "\n")
tabs_oe <- paste(c('<button class="tab active" data-target="sec-open">Open-ended answers</button>',
  '<button class="tab" data-target="sec-codebook">Codebook</button>',
  '<select id="txsel"><option value="">Select a question&hellip;</option>', q_options, '</select>'), collapse = "\n")

# sprintf caps the format string at 8192 bytes, so the page is two pieces. The same
# template serves both pages: transcripts (with the Codebook tab) and open-ended answers
# (with the Codebook tab), built from one run.
render_page <- function(title, heading, sub, tabs, body) paste0(sprintf('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>%s</title>
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
  .brow-oe { grid-template-columns: 290px 1fr 44px 52px 52px 52px; }
  table.qlist { border-collapse:collapse; max-width:1100px; font-size:13px; margin-bottom:8px; }
  table.qlist th { text-align:left; font-size:10.5px; letter-spacing:.07em; text-transform:uppercase; color:#888; border-bottom:2px solid var(--navy); padding:4px 10px 4px 0; }
  table.qlist td { vertical-align:top; padding:7px 10px 7px 0; border-bottom:1px solid #ececec; }
  .goto-sec { font:inherit; color:var(--navy); background:none; border:none; cursor:pointer; text-decoration:underline; padding:0; text-align:left; }
  .qtext { font-family:Georgia,serif; font-size:15px; margin:4px 0 6px; max-width:900px; }
  .acard { background:#fff; border:1px solid #e2e2e2; border-radius:6px; padding:12px 16px; margin-bottom:10px; max-width:900px; }
  .ameta { font-size:11px; color:#888; margin-bottom:4px; }
  .atext { font-family:Georgia,serif; font-size:14px; line-height:1.55; }
  .achips { margin-top:8px; }
  .achip { font-family:ui-monospace,Menlo,monospace; font-size:11px; font-weight:600; color:var(--navy); padding:2px 7px; border-radius:3px; margin-right:2px; border:1px solid rgba(0,0,0,.12); }
  .nocode { font-size:11px; color:#999; font-style:italic; }
  .goto-ans { font:inherit; font-size:11px; color:var(--navy); background:none; border:none; cursor:pointer; text-decoration:underline; padding:0; margin-left:6px; }
</style></head><body>
<header><h1>%s — IMCC Codebook v%s</h1>
<div class="sub">Run <code>%s</code>: %s, effort %s, %s. %s Model output, not yet reviewed against human coding.</div></header>
<nav class="tabs">%s</nav>
<div class="legend">%s</div>
%s
<footer>Generated by scripts/nlp/coding_dashboard.R from data/processed/llm-coding/%s/.</footer>
', title, heading, cb_version, manifest$run_id, manifest$model, manifest$effort, manifest$run_date %||% substr(manifest$started, 1, 10),
   sub, tabs, legend, body, manifest$run_id), '<script>
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
  if (sel) { sel.classList.remove("active"); sel.value = ""; }
}));
if (sel) sel.addEventListener("change", () => {
  if (!sel.value) return;
  show(sel.value); sel.classList.add("active"); tabBtns.forEach(x => x.classList.remove("active"));
});
show(tabBtns[0].dataset.target);
// Overview: click a code row to list every passage assigned that code
document.querySelectorAll(".brow[data-code]").forEach(r => r.addEventListener("click", () => {
  r.classList.toggle("open"); r.nextElementSibling.classList.toggle("open");
}));
document.querySelectorAll(".goto").forEach(b => b.addEventListener("click", e => {
  e.stopPropagation();
  show(b.dataset.sec); if (sel) { sel.value = b.dataset.sec; sel.classList.add("active"); }
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
document.querySelectorAll(".goto-sec").forEach(b => b.addEventListener("click", () => {
  show(b.dataset.sec); if (sel) { sel.value = b.dataset.sec; sel.classList.add("active"); }
  tabBtns.forEach(x => x.classList.remove("active")); window.scrollTo({top: 0});
}));
document.querySelectorAll(".goto-ans").forEach(b => b.addEventListener("click", e => {
  e.stopPropagation();
  show(b.dataset.sec); if (sel) { sel.value = b.dataset.sec; sel.classList.add("active"); }
  tabBtns.forEach(x => x.classList.remove("active"));
  const card = document.getElementById(`ans-${b.dataset.ans}`);
  card.scrollIntoView({behavior:"smooth", block:"center"});
  card.style.outline = "2px solid var(--navy)"; setTimeout(() => card.style.outline = "", 2500);
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

click_help <- "Click a code row to jump to its passage; click a highlight to see its codes (dotted underline = multiple codes overlap)."
pages <- list(
  "dashboard.html"  = render_page("1MCC — Coded interview transcripts", "Coded interview transcripts", click_help,
                                  tabs_tx, paste(overview, codebook_tab, sections, unused_note, sep = "\n")),
  "open-ended.html" = render_page("1MCC — Coded open-ended answers", "Coded open-ended answers",
                                  "Click a code to list its passages; pick a question from the dropdown to read every answer with its excerpts highlighted.",
                                  tabs_oe, paste(open_tab, codebook_tab, paste(question_sections, collapse = "\n"), unused_note, sep = "\n")))
site_names <- c("dashboard.html" = "index.html", "open-ended.html" = "open-ended.html")
for (nm in names(pages)) {
  out <- file.path(run_dir, nm)
  writeLines(pages[[nm]], out, useBytes = FALSE)
  cat("Wrote", out, "\n")
  if (to_site) {
    dir.create(here("coding-dashboard"), showWarnings = FALSE)
    file.copy(out, here("coding-dashboard", site_names[[nm]]), overwrite = TRUE)
    cat("Copied to coding-dashboard/", site_names[[nm]], " (site resource)\n", sep = "")
  }
}
