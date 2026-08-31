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
#   - a previously-fetched delivery whose sha1 changed upstream stops the sync
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

listing <- as.data.frame(box_ls(folder_id)) |>
  filter(type == "file") |>
  select(any_of(c("name", "id", "sha1", "file_version_id", "version_id",
                  "size", "content_modified_at")))

manifest <- if (file.exists(manifest_path)) {
  read_csv(manifest_path, col_types = cols(.default = "c"))
} else {
  tibble(name = character(), id = character(), sha1 = character())
}

## Upstream modifications are an event, not a refetch --------------------------

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

# log records names without extension, sometimes with stray whitespace/newlines;
# some delivered filenames carry trailing underscore padding the log omits
normalize <- \(x) str_remove(str_trim(str_remove_all(x, "[\r\n]")), "_+$")
logged_names <- normalize(delivery_log[[name_col]])
box_names <- listing |>
  filter(id != log_entry$id) |>
  pull(name) |>
  tools::file_path_sans_ext() |>
  normalize()

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

not_skimmed <- logged_names[normalize(delivery_log[[pii_col]]) != "Yes"]
if (length(not_skimmed) > 0) {
  cli::cli_abort(c(
    "{length(not_skimmed)} deliver{?y/ies} not marked PII-skimmed in the DATA LOG — not downloading:",
    set_names(not_skimmed, rep("x", length(not_skimmed)))
  ))
}

## Fetch new deliveries by file ID --------------------------------------------

new_files <- listing |> anti_join(manifest, by = "id")

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
  mutate(fetched_at = format(Sys.time(), tz = "UTC", "%Y-%m-%dT%H:%M:%SZ")) |>
  write_csv(manifest_path)

cli::cli_inform("Manifest written to {.path {manifest_path}}.")
