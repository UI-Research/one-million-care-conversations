# Sync data/raw/ from the Box delivery folder via the Box API, and turn the
# team's DATA LOG into a delivery table the cleaning step classifies files by.
#
# The Box API listing is the ground truth for what has been delivered — unlike
# a Box Drive mount, there is no sync daemon whose staleness could go unnoticed.
# Files are downloaded by file ID (immune to naming quirks like trailing
# spaces), recorded in data/raw/box-manifest.csv (file ID, version, sha1), and
# validated against the `* DATA LOG *.xlsx` manifest the team maintains.
#
# Outputs:
#   data/raw/Raw data backups/        top-level deliveries, names as on Box
#   data/raw/interview-transcripts/   files from the "Interview Transcripts"
#                                     subfolder (any depth), flattened
#   data/raw/box-manifest.csv         every file seen on Box, with sha1
#   data/raw/deliveries.csv           one row per delivered file with what the
#                                     DATA LOG says it is (tool, form, closed or
#                                     open, complete or partial, test flag,
#                                     collection window, ID range, notes)
#
# Everything here fails loudly:
#   - a file on Box missing from the DATA LOG (or vice versa) stops the sync
#   - a previously-fetched delivery modified or deleted upstream stops the sync
#   - duplicate filenames (which would confuse the log lookup) stop the sync
#   - a delivery not marked "Yes" under "Skimmed for PII?" is never downloaded
#   - a DATA LOG tool type the parser does not recognize stops the sync
#
# One-time setup:
#   1. `box_auth()` in an R console (browser login; token is cached locally)
#   2. Add to ~/.Renviron: BOX_RAW_FOLDER_ID=<id from the folder's Box URL>
#
# Downstream (01_clean-data.qmd) reads only the local copy, so rendering never
# needs Box auth — this script is the sole Box touchpoint.

library(tidyverse)
library(boxr)
library(readxl)
library(here)

raw_dir <- here("data/raw/Raw data backups")
transcripts_dir <- here("data/raw/interview-transcripts")
manifest_path <- here("data/raw/box-manifest.csv")
deliveries_path <- here("data/raw/deliveries.csv")

folder_id <- Sys.getenv("BOX_RAW_FOLDER_ID")
if (folder_id == "") {
  cli::cli_abort(c(
    "BOX_RAW_FOLDER_ID is not set.",
    "i" = "Open the delivery folder in the Box web UI and copy the ID from the URL",
    "i" = "(https://urbanorg.app.box.com/folder/<ID>), then add",
    "i" = "BOX_RAW_FOLDER_ID=<ID> to ~/.Renviron and restart R."
  ))
}

box_auth()

## Authoritative listing ------------------------------------------------------

keep_cols <- c("name", "id", "type", "sha1", "file_version_id", "version_id",
               "size", "content_modified_at")

# every file below a folder, any depth, tagged with the top-level subfolder
# it sits under
list_files_below <- function(folder_id, under) {
  contents <- as.data.frame(box_ls(folder_id)) |> select(any_of(keep_cols))
  files <- contents |> filter(type == "file") |> mutate(under = under)
  subfolders <- contents |> filter(type == "folder")
  bind_rows(files, map(subfolders$id, \(id) list_files_below(id, under)) |> list_rbind())
}

top <- as.data.frame(box_ls(folder_id)) |> select(any_of(keep_cols))
subfolders <- top |> filter(type == "folder")
listing <- bind_rows(
  top |> filter(type == "file") |> mutate(under = ""),
  map2(subfolders$id, subfolders$name, list_files_below) |> list_rbind()
) |>
  select(-type)

manifest <- if (file.exists(manifest_path)) {
  read_csv(manifest_path, col_types = cols(.default = "c"))
} else {
  tibble(name = character(), id = character(), sha1 = character())
}

## Upstream modification or deletion is an event, not a refetch ----------------

modified <- listing |>
  filter(!str_detect(name, "DATA LOG")) |> # the log is a living manifest — expected to change
  inner_join(manifest, by = "id", suffix = c("", "_fetched")) |>
  filter(sha1 != sha1_fetched)
if (nrow(modified) > 0) {
  cli::cli_abort(c(
    "{nrow(modified)} previously-fetched deliver{?y/ies} modified on Box — investigate
     with the team (Box web UI keeps the version history) before re-syncing:",
    set_names(modified$name, rep("x", nrow(modified)))
  ))
}

deleted <- anti_join(manifest, listing, by = "id")
if (nrow(deleted) > 0) {
  cli::cli_abort(c(
    "{nrow(deleted)} previously-fetched file{?s} no longer on Box — investigate
     before re-syncing (the local cop{?y/ies} would otherwise go stale silently):",
    set_names(deleted$name, rep("x", nrow(deleted)))
  ))
}

## Read the team's DATA LOG ---------------------------------------------------

log_entry <- listing |> filter(under == "", str_detect(name, "DATA LOG"))
if (nrow(log_entry) != 1) {
  cli::cli_abort("Expected exactly one DATA LOG file in the Box folder, found {nrow(log_entry)}.")
}
log_path <- box_dl(log_entry$id, local_dir = raw_dir, overwrite = TRUE)

delivery_log <- read_excel(log_path, sheet = "Details", col_types = "text") |>
  rename_with(str_squish)
log_col <- function(pattern) {
  hit <- str_subset(names(delivery_log), regex(pattern, ignore_case = TRUE))
  if (length(hit) != 1) {
    cli::cli_abort("DATA LOG 'Details' sheet: expected one column matching {.val {pattern}}, found {length(hit)}.")
  }
  hit
}

# log records names without extension, with stray whitespace and inconsistent
# case ("F1"); some delivered filenames carry trailing underscore padding or a
# space before the extension that the log omits. One log cell may list several
# files on separate lines (the interview transcripts), so split those first.
normalize <- \(x) str_to_lower(str_remove(str_trim(x), "_+$"))

# free-text collection windows: "6/4-7/10", "6/8 to 6/9", "8/1-8/1", a bare
# Excel serial for a single day, or text like "Unknown" (-> NA). The year is
# the delivery year (the log has no year in these cells).
parse_day <- function(x, year) {
  x <- str_trim(x)
  case_when(
    str_detect(x, "^\\d{1,2}/\\d{1,2}$") ~ as.Date(str_c(year, "/", x), format = "%Y/%m/%d"),
    str_detect(x, "^\\d{5}$")             ~ as.Date(as.numeric(x), origin = "1899-12-30"),
    TRUE                                  ~ as.Date(NA)
  )
}
parse_window <- function(x, year) {
  parts <- str_split_fixed(str_replace(coalesce(x, ""), "\\s+to\\s+", "-"), "-", 2)
  start <- parse_day(parts[, 1], year)
  end   <- parse_day(parts[, 2], year)
  tibble(collection_start = start, collection_end = coalesce(end, start))
}

log_rows <- delivery_log |>
  transmute(
    name       = .data[[log_col("^Raw file name")]],
    delivered  = as.Date(as.numeric(.data[[log_col("^Date$")]]), origin = "1899-12-30"),
    activity   = .data[[log_col("^Activity")]],
    tool_type  = .data[[log_col("tool type")]],
    status_raw = .data[[log_col("^Complete or partial")]],
    skimmed    = .data[[log_col("Skimmed for PII")]],
    collection = .data[[log_col("^Collection dates")]],
    first_id   = .data[[log_col("^First ID")]],
    last_id    = .data[[log_col("^Last ID")]],
    notes      = .data[[log_col("^Notes")]]
  ) |>
  separate_longer_delim(name, regex("[\r\n]+")) |>
  mutate(name = normalize(name), skimmed = normalize(skimmed)) |>
  filter(!is.na(name), name != "")

# What the log says each file is. The tool-type cell is typed by hand
# ("Survey (F2), closed", "Canvas (c1), closed", "Canvas, open text", ...), so
# it is parsed into pieces; the file name is a second opinion used to fill
# gaps and to flag disagreement, never to override the log.
log_rows <- log_rows |>
  mutate(
    tt = str_to_lower(tool_type),
    tool = case_when(
      str_detect(tt, "one question poll|pre-launch") ~ "poll",
      str_detect(tt, "^survey")                      ~ "survey",
      str_detect(tt, "^canvas")                      ~ "canvass",
      str_detect(tt, "^interview")                   ~ "interview",
      TRUE                                           ~ NA_character_
    ),
    form_log     = str_match(tt, "\\(([fc]\\d)\\)")[, 2],
    content_log  = case_when(str_detect(tt, "open") ~ "open", str_detect(tt, "closed") ~ "closed"),
    form_name    = str_match(name, "_([fc]\\d)_")[, 2],
    content_name = case_when(
      str_detect(name, "_open(text)?(_|$)") ~ "open",
      str_detect(name, "_closed(_|$)")      ~ "closed"
    ),
    form    = coalesce(form_log, form_name),
    content = coalesce(content_log, content_name),
    status  = case_when(
      str_detect(str_to_lower(status_raw), "complete") ~ "complete",
      str_detect(str_to_lower(status_raw), "partial")  ~ "partial"
    ),
    test        = str_detect(str_to_lower(activity), "test"),
    pii_skimmed = skimmed == "yes",
    # "00000 (from file name)" and "N/A" appear here; those become NA
    first_id    = suppressWarnings(parse_number(first_id)),
    last_id     = suppressWarnings(parse_number(last_id)),
    parse_window(collection, year(delivered))
  ) |>
  select(-tt)

unknown_tool <- log_rows |> filter(is.na(tool))
if (nrow(unknown_tool) > 0) {
  cli::cli_abort(c(
    "DATA LOG tool type{?s} the parser does not recognize — extend the rules in this script:",
    set_names(unique(unknown_tool$tool_type), rep("x", n_distinct(unknown_tool$tool_type)))
  ))
}
disagree <- log_rows |>
  filter((!is.na(form_log) & !is.na(form_name) & form_log != form_name) |
         (!is.na(content_log) & !is.na(content_name) & content_log != content_name))
if (nrow(disagree) > 0) {
  cli::cli_warn(c(
    "DATA LOG and file name disagree for {nrow(disagree)} file{?s} (the log is used):",
    set_names(str_c(disagree$name, ": log says ", disagree$tool_type), rep("!", nrow(disagree)))
  ))
}

## Reconcile Box against the log ----------------------------------------------

box_files <- listing |>
  filter(id != log_entry$id) |>
  mutate(key = normalize(tools::file_path_sans_ext(name)))

# the PII gate below is keyed by name — duplicate normalized names would let
# one log row green-light more than one file, so refuse to continue
dup_names <- c(box_files$key[duplicated(box_files$key)], log_rows$name[duplicated(log_rows$name)])
if (length(dup_names) > 0) {
  cli::cli_abort(c(
    "Duplicate filename{?s} (after normalization) on Box or in the DATA LOG:",
    set_names(unique(dup_names), rep("x", length(unique(dup_names))))
  ))
}

unlogged <- setdiff(box_files$key, log_rows$name)
missing <- setdiff(log_rows$name, box_files$key)
if (length(unlogged) > 0 || length(missing) > 0) {
  bullets <- c(
    set_names(str_c("On Box but not in the DATA LOG: ", unlogged), rep("x", length(unlogged))),
    set_names(str_c("In the DATA LOG but not on Box: ", missing), rep("x", length(missing)))
  )
  cli::cli_abort(c(
    "Box folder and DATA LOG disagree — ask the team to reconcile before syncing:",
    bullets
  ))
}

not_skimmed <- log_rows$name[!log_rows$pii_skimmed]
if (length(not_skimmed) > 0) {
  cli::cli_abort(c(
    "{length(not_skimmed)} deliver{?y/ies} not marked PII-skimmed in the DATA LOG — not downloading:",
    set_names(not_skimmed, rep("x", length(not_skimmed)))
  ))
}

## Fetch new deliveries by file ID --------------------------------------------

# top-level files go to the mirror; anything under "Interview Transcripts"
# (however deep) goes to the transcripts folder, flattened
box_files <- box_files |>
  mutate(local_dir = if_else(str_detect(under, regex("interview transcripts", ignore_case = TRUE)),
                             transcripts_dir, raw_dir))
new_files <- anti_join(box_files, manifest, by = "id")

if (nrow(new_files) == 0) {
  cli::cli_inform("Mirror is up to date ({nrow(box_files)} files, nothing new).")
} else {
  cli::cli_inform("Fetching {nrow(new_files)} new file{?s}:")
  pwalk(new_files[c("id", "name", "local_dir")], \(id, name, local_dir) {
    dir.create(local_dir, showWarnings = FALSE, recursive = TRUE)
    box_dl(id, local_dir = local_dir, overwrite = TRUE)
    cli::cli_inform("  {.file {name}}")
  })
}

listing |>
  # fetched_at means "last verified against Box", not first download
  mutate(fetched_at = format(Sys.time(), tz = "UTC", "%Y-%m-%dT%H:%M:%SZ")) |>
  write_csv(manifest_path)

## Delivery table for the cleaning step ---------------------------------------

deliveries <- box_files |>
  left_join(log_rows, by = c("key" = "name")) |>
  transmute(
    file = name, folder = if_else(under == "", "Raw data backups", under),
    delivered, tool, form, content, status, test,
    collection_start, collection_end, first_id, last_id, pii_skimmed, tool_type, notes
  ) |>
  arrange(delivered, file)
write_csv(deliveries, deliveries_path)

cli::cli_inform("Manifest written to {.path {manifest_path}}; {nrow(deliveries)} deliveries described in {.path {deliveries_path}}.")
