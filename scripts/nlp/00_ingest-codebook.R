# Turn the newest codebook workbook into data/processed/codebook.csv, the one
# file the coding prompt, the dashboards, and any counting read.
#
# Bree maintains the codebook as "IMCC Codebook v<N>.xlsx" (one sheet, seven
# columns: Domain, Parent_Code, Code, Definition, Include, Exclude, Keywords).
# Drop each version into data/raw/codebook/; this script picks the highest
# version number, checks the layout, and writes the CSV with a `version`
# column so every coded output can say which codebook it used.
#
# Stops on: missing columns, a code listed twice, or an empty code/definition.

library(tidyverse)
library(readxl)
library(here)

codebook_dir <- here("data/raw/codebook")
out_path <- here("data/processed/codebook.csv")

files <- tibble(path = list.files(codebook_dir, pattern = "\\.xlsx$", full.names = TRUE)) |>
  mutate(version = as.integer(str_match(basename(path), "v\\.?\\s*(\\d+)")[, 2])) |>
  filter(!is.na(version)) |>
  arrange(desc(version))
if (nrow(files) == 0) cli::cli_abort("No 'IMCC Codebook v<N>.xlsx' in {.path {codebook_dir}}")
newest <- files[1, ]
cli::cli_inform("Reading {.file {basename(newest$path)}} (version {newest$version})")

expected <- c("Domain", "Parent_Code", "Code", "Definition", "Include", "Exclude", "Keywords")
raw <- read_excel(newest$path, col_types = "text") |> rename_with(str_squish)
missing <- setdiff(expected, names(raw))
if (length(missing)) cli::cli_abort("Codebook is missing column{?s} {.val {missing}}")

codebook <- raw |>
  select(all_of(expected)) |>
  rename(domain = Domain, parent = Parent_Code, code = Code, definition = Definition,
         include = Include, exclude = Exclude, keywords = Keywords) |>
  mutate(across(everything(), str_squish),
         code = str_replace_all(code, "\\s+", ""), # "CARE_ PRIMARY" -> "CARE_PRIMARY"
         version = newest$version) |>
  filter(!if_all(c(domain, code, definition), is.na))

bad <- codebook |> filter(is.na(code) | is.na(definition) | is.na(domain))
if (nrow(bad)) cli::cli_abort("{nrow(bad)} codebook row{?s} with an empty domain, code, or definition")
dup <- codebook$code[duplicated(codebook$code)]
if (length(dup)) cli::cli_abort("Code{?s} listed more than once: {.val {unique(dup)}}")

write_csv(codebook, out_path)
cli::cli_inform("Wrote {nrow(codebook)} codes in {n_distinct(codebook$domain)} domains to {.path {out_path}}")
