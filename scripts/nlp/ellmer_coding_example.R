# Minimal ellmer example: apply the IMCC codebook to transcript segments via Claude on
# Amazon Bedrock, returning structured output. This is the *test* version — the
# production pipeline is Python (see PLAN-llm-coding.md). Same prompt file, same
# schema, so results are comparable.
#
# Usage:   Rscript scripts/nlp/ellmer_coding_example.R [n_segments]
#          (default 5 — smoke test; drop the cap only after checking cost)
# Needs:   ellmer >= 0.3, pandoc, AWS credentials resolvable by paws (env vars,
#          AWS_PROFILE, or `aws sso login`), and the model enabled in Urban's Bedrock.
# Output:  data/processed/interview-coding/llm_ellmer_<model>.csv (gitignored)
#
# Not yet run against Bedrock — confirm model ID and region with Rob first.

library(here)
library(ellmer)
library(purrr)
library(dplyr)

n_max    <- as.integer(commandArgs(trailingOnly = TRUE)[1])
if (is.na(n_max)) n_max <- 5L
model_id <- Sys.getenv("IMCC_MODEL", "us.anthropic.claude-sonnet-5")  # Bedrock inference profile ID
raw_dir  <- here("data", "raw", "interview-transcripts")
out_dir  <- here("data", "processed", "interview-coding")

docx_to_lines <- function(path, to = "plain") {
  tmp <- tempfile(fileext = ".txt")
  system2("pandoc", c(shQuote(path), "-t", to, "--wrap=none", "-o", shQuote(tmp)))
  readLines(tmp, encoding = "UTF-8", warn = FALSE)
}

# ---- codebook docx -> tibble -> markdown table for the prompt ------------------------

cb <- docx_to_lines(here("IMCC Codebook v3.docx"), to = "gfm") |>
  keep(\(l) startsWith(l, "|") && !grepl("^\\|[-| ]+\\|$", l) && !grepl("**Domain**", l, fixed = TRUE)) |>
  map(\(l) trimws(strsplit(sub("\\|$", "", sub("^\\|", "", l)), "|", fixed = TRUE)[[1]])) |>
  map(\(x) as_tibble(set_names(as.list(gsub("\\\\", "", x)),
                     c("domain", "parent", "code", "definition", "include", "exclude", "keywords")))) |>
  list_rbind() |>
  mutate(code = gsub("_+", "_", gsub(" ", "", code)))   # docx typos: "CARE_ PRIMARY", "CARE__DAILY"

write.csv(cb, file.path(out_dir, "codebook.csv"), row.names = FALSE)  # flat copy for Bree + Python

codebook_md <- paste(c(
  "| Domain | Parent | Code | Definition | Include | Exclude | Keywords |",
  "|---|---|---|---|---|---|---|",
  sprintf("| %s |", apply(cb, 1, paste, collapse = " | "))), collapse = "\n")

# ---- transcripts -> participant segments (speaker turns) ------------------------------

segment_transcript <- function(docx) {
  stem  <- sub("\\.docx$", "", basename(docx))
  lines <- trimws(docx_to_lines(docx))
  lines <- lines[nzchar(lines)]
  is_label <- grepl("^[A-Z][A-Za-z0-9 ]{0,25}:", lines)
  if (sum(is_label) < 5)                                    # the letter: no turns, one segment
    return(tibble(file = stem, speaker = "letter", text = paste(lines, collapse = "\n")))
  tibble(line = lines, turn = cumsum(is_label)) |>
    filter(turn > 0) |>
    summarise(speaker = sub(":.*$", "", first(line)),
              text = paste(c(sub("^[^:]+:\\s*", "", first(line)), line[-1]), collapse = " "),
              .by = turn) |>
    filter(!grepl("^(Facilitator|Interviewer|Date|Zipcode|Participants)", speaker),
           nchar(text) >= 40) |>
    transmute(file = stem, speaker, text)
}

docx_files  <- list.files(raw_dir, pattern = "\\.docx$", full.names = TRUE)
stems       <- sub("\\.docx$", "", basename(docx_files))
transcripts <- set_names(map_chr(docx_files, \(f) paste(docx_to_lines(f), collapse = "\n")), stems)
segments    <- map(docx_files, segment_transcript) |> list_rbind() |>
  mutate(segment_id = sprintf("%s_%03d", file, row_number()), .by = file)
cat(nrow(segments), "participant segments; coding the first", min(n_max, nrow(segments)), "\n")

# ---- prompt + schema (shared with the Python version) ----------------------------------

system_prompt <- paste0(
  paste(readLines(here("scripts", "nlp", "coding_prompt.md"), warn = FALSE), collapse = "\n"),
  "\n\n## Codebook\n\n", codebook_md)

coded_segment <- type_object(
  segment_id = type_string(),
  codes = type_array(type_object(
    code       = type_string("A code name from the codebook"),
    excerpt    = type_string("Shortest verbatim span from the segment supporting the code"),
    rationale  = type_string("One sentence referencing the codebook definition"),
    confidence = type_enum(c("high", "medium", "low"))
  ), "Empty when no code applies"),
  possible_new_code = type_string("Proposed code name + definition when an _OTHER code was used",
                                  required = FALSE)
)

# ---- run ---------------------------------------------------------------------------

# Thinking is disabled because ellmer 0.4.0's Bedrock provider errors on the
# "reasoningContent" blocks Sonnet 5 returns with adaptive thinking on. The Python
# version keeps thinking on (effort medium); re-enable here when ellmer supports it.
# Note also: no prompt caching via this path (cached_input stays 0), so the transcript
# context is billed on every call — fine for a smoke test, not for the full run.
chat <- chat_aws_bedrock(
  system_prompt = system_prompt, model = model_id, echo = "none",
  api_args = list(additionalModelRequestFields = list(thinking = list(type = "disabled"))))

todo <- head(segments, n_max)
prompts <- pmap(todo, \(file, speaker, text, segment_id) interpolate(
  "## Full transcript (context only)\n\n{{transcripts[[file]]}}\n\n## Code this segment\n\nsegment_id: {{segment_id}}\nspeaker: {{speaker}}\n\n{{text}}"))

results <- parallel_chat_structured(chat, prompts, type = coded_segment, convert = FALSE)

coded <- imap(results, \(r, i) {
  if (length(r$codes) == 0) return(NULL)
  tibble(segment_id = todo$segment_id[i], file = todo$file[i], speaker = todo$speaker[i],
         code = map_chr(r$codes, "code"), excerpt = map_chr(r$codes, "excerpt"),
         rationale = map_chr(r$codes, "rationale"), confidence = map_chr(r$codes, "confidence"),
         possible_new_code = r$possible_new_code %||% NA_character_)
}) |> list_rbind() |>
  mutate(model = model_id, run_date = Sys.Date())

unknown <- setdiff(coded$code, cb$code)   # structured output guarantees shape, not vocabulary
if (length(unknown)) warning("codes not in codebook: ", paste(unknown, collapse = ", "))

out <- file.path(out_dir, sprintf("llm_ellmer_%s.csv", gsub("[^a-z0-9]+", "-", tolower(model_id))))
write.csv(coded, out, row.names = FALSE)
cat("Wrote", nrow(coded), "code assignments to", out, "\n")
print(token_usage())
