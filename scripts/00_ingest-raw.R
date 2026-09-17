# Sync data/raw/Raw data backups/ from the Box delivery folder via the Box API.
#
# The Box API listing is the ground truth for what has been delivered — unlike
# a Box Drive mount, there is no sync daemon whose staleness could go unnoticed.
# Files are downloaded by file ID (immune to naming quirks like trailing
# spaces), recorded in data/raw/box-manifest.csv (file ID, version, sha1), and
# validated against the `* DATA LOG *.xlsx` manifest the team maintains.
#
# Everything here fails loudly:
#   - a file on Box missing from the DATA LOG (or vice versa) stops the sync
#   - a previously-fetched delivery modified or deleted upstream stops the sync
#   - duplicate filenames (which would confuse the log lookup) stop the sync
#   - a delivery not marked "Yes" under "Skimmed for PII?" is never downloaded
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
manifest_path <- here("data/raw/box-manifest.csv")

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

listing_all <- as.data.frame(box_ls(folder_id))
listing <- listing_all |>
  filter(type == "file") |>
  select(any_of(c("name", "id", "sha1", "file_version_id", "version_id",
                  "size", "content_modified_at")))

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

## Reconcile against the team's DATA LOG --------------------------------------

log_entry <- listing |> filter(str_detect(name, "DATA LOG"))
if (nrow(log_entry) != 1) {
  cli::cli_abort("Expected exactly one DATA LOG file in the Box folder, found {nrow(log_entry)}.")
}
log_path <- box_dl(log_entry$id, local_dir = raw_dir, overwrite = TRUE)

delivery_log <- read_excel(log_path) |>
  rename_with(str_trim)
name_col <- str_subset(names(delivery_log), "Raw file name")
pii_col <- str_subset(names(delivery_log), "Skimmed for PII")
if (length(name_col) != 1 || length(pii_col) != 1) {
  cli::cli_abort("DATA LOG columns changed — expected one 'Raw file name' and one 'Skimmed for PII' column.")
}

# log records names without extension, with stray whitespace and inconsistent
# case ("F1"); some delivered filenames carry trailing underscore padding or a
# space before the extension that the log omits. One log cell may list several
# files on separate lines (the interview transcripts), so split those first.
normalize <- \(x) str_to_lower(str_remove(str_trim(x), "_+$"))
log_rows <- delivery_log |>
  transmute(name = .data[[name_col]], skimmed = .data[[pii_col]]) |>
  separate_longer_delim(name, regex("[\r\n]+")) |>
  mutate(name = normalize(name), skimmed = normalize(skimmed)) |>
  filter(!is.na(name), name != "")
logged_names <- log_rows$name

# the log covers subfolders too (interview transcripts, nested by delivery
# date), so reconcile against every file below the folder; only top-level
# files are mirrored here
list_files_below <- function(folder_ids) {
  if (length(folder_ids) == 0) return(tibble(name = character()))
  contents <- map(folder_ids, \(id) as.data.frame(box_ls(id))) |> list_rbind()
  bind_rows(
    contents |> filter(type == "file") |> select(name),
    list_files_below(contents |> filter(type == "folder") |> pull(id))
  )
}
subfolder_files <- list_files_below(listing_all |> filter(type == "folder") |> pull(id))
box_names <- bind_rows(filter(listing, id != log_entry$id), subfolder_files) |>
  pull(name) |>
  tools::file_path_sans_ext() |>
  normalize()

# the PII gate below is keyed by name — duplicate normalized names would let
# one log row green-light more than one file, so refuse to continue
dup_names <- c(box_names[duplicated(box_names)], logged_names[duplicated(logged_names)])
if (length(dup_names) > 0) {
  cli::cli_abort(c(
    "Duplicate filename{?s} (after normalization) on Box or in the DATA LOG:",
    set_names(unique(dup_names), rep("x", length(unique(dup_names))))
  ))
}

unlogged <- setdiff(box_names, logged_names)
missing <- setdiff(logged_names, box_names)
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

not_skimmed <- log_rows$name[log_rows$skimmed != "yes"]
if (length(not_skimmed) > 0) {
  cli::cli_abort(c(
    "{length(not_skimmed)} deliver{?y/ies} not marked PII-skimmed in the DATA LOG — not downloading:",
    set_names(not_skimmed, rep("x", length(not_skimmed)))
  ))
}

## Fetch new deliveries by file ID --------------------------------------------

new_files <- listing |>
  anti_join(manifest, by = "id") |>
  filter(id != log_entry$id) # the log was already downloaded above

if (nrow(new_files) == 0) {
  cli::cli_inform("Mirror is up to date ({nrow(listing)} files, nothing new).")
} else {
  cli::cli_inform("Fetching {nrow(new_files)} new file{?s}:")
  walk2(new_files$id, new_files$name, \(id, name) {
    box_dl(id, local_dir = raw_dir, overwrite = TRUE)
    cli::cli_inform("  {.file {name}}")
  })
}

listing |>
  # fetched_at means "last verified against Box", not first download
  mutate(fetched_at = format(Sys.time(), tz = "UTC", "%Y-%m-%dT%H:%M:%SZ")) |>
  write_csv(manifest_path)

cli::cli_inform("Manifest written to {.path {manifest_path}}.")
