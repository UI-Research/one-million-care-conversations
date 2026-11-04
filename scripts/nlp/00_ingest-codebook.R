# Turn a codebook into data/processed/codebook.csv, the one file the coding
# prompt, the dashboards, and any counting read.
#
# Bree maintains the codebook as "IMCC Codebook v<N>.xlsx" (one sheet, seven
# columns: Domain, Parent_Code, Code, Definition, Include, Exclude, Keywords),
# and earlier versions only as "IMCC Codebook v<N>.docx" (the same seven
# columns, one table per domain). Drop each version into data/raw/codebook/;
# this script picks the highest version number, checks the layout, and writes
# the CSV with a `version` column so every coded output can say which codebook
# it used.
#
#   Rscript scripts/nlp/00_ingest-codebook.R      # newest -> codebook.csv
#   Rscript scripts/nlp/00_ingest-codebook.R 5    # version 5 -> codebook_v5.csv
#
# Stops on: missing columns, a code listed twice, or an empty code/definition.

library(tidyverse)
library(readxl)
library(here)

codebook_dir <- here("data/raw/codebook")
version_arg <- as.integer(commandArgs(trailingOnly = TRUE)[1])

files <- tibble(path = list.files(codebook_dir, pattern = "\\.(xlsx|docx)$", full.names = TRUE)) |>
  filter(!str_starts(basename(path), "~\\$")) |>
  mutate(version = as.integer(str_match(basename(path), "v\\.?\\s*(\\d+)")[, 2])) |>
  filter(!is.na(version)) |>
  arrange(desc(version), desc(str_ends(path, "xlsx")))  # a version's workbook wins over its document
if (nrow(files) == 0) cli::cli_abort("No 'IMCC Codebook v<N>.xlsx' in {.path {codebook_dir}}")
chosen <- if (is.na(version_arg)) files[1, ] else filter(files, version == version_arg)[1, ]
if (is.na(chosen$path)) cli::cli_abort("No codebook version {version_arg} in {.path {codebook_dir}}")
out_path <- here("data/processed", if (is.na(version_arg)) "codebook.csv" else str_glue("codebook_v{version_arg}.csv"))
cli::cli_inform("Reading {.file {basename(chosen$path)}} (version {chosen$version})")

# every table row in a Word codebook, header rows dropped; a cell's paragraphs
# are joined with spaces
read_docx_tables <- function(path) {
  xml_path <- unzip(path, "word/document.xml", exdir = tempfile())
  doc <- xml2::read_xml(xml_path)
  ns <- xml2::xml_ns(doc)
  cells <- xml2::xml_find_all(doc, "//w:tbl/w:tr", ns) |>
    map(\(row) {
      xml2::xml_find_all(row, "w:tc", ns) |>
        map_chr(\(cell) {
          xml2::xml_find_all(cell, ".//w:p", ns) |>
            map_chr(\(p) str_c(xml2::xml_text(xml2::xml_find_all(p, ".//w:t", ns)), collapse = "")) |>
            str_c(collapse = " ")
        })
    })
  header <- cells[[1]]
  cells |>
    keep(\(row) length(row) == length(header) && !identical(row, header)) |>
    map(\(row) set_names(as.list(row), header)) |>
    bind_rows()
}

expected <- c("Domain", "Parent_Code", "Code", "Definition", "Include", "Exclude", "Keywords")
raw <- if (str_ends(chosen$path, "docx")) read_docx_tables(chosen$path) else read_excel(chosen$path, col_types = "text")
raw <- rename_with(raw, str_squish)
missing <- setdiff(expected, names(raw))
if (length(missing)) cli::cli_abort("Codebook is missing column{?s} {.val {missing}}")

codebook <- raw |>
  select(all_of(expected)) |>
  rename(domain = Domain, parent = Parent_Code, code = Code, definition = Definition,
         include = Include, exclude = Exclude, keywords = Keywords) |>
  mutate(across(everything(), \(x) na_if(str_squish(x), "")),
         code = str_replace_all(code, "\\s+", ""), # "CARE_ PRIMARY" -> "CARE_PRIMARY"
         version = chosen$version) |>
  filter(!if_all(c(domain, code, definition), is.na))

bad <- codebook |> filter(is.na(code) | is.na(definition) | is.na(domain))
if (nrow(bad)) cli::cli_abort("{nrow(bad)} codebook row{?s} with an empty domain, code, or definition")
dup <- codebook$code[duplicated(codebook$code)]
if (length(dup)) cli::cli_abort("Code{?s} listed more than once: {.val {unique(dup)}}")

write_csv(codebook, out_path)
cli::cli_inform("Wrote {nrow(codebook)} codes in {n_distinct(codebook$domain)} domains to {.path {out_path}}")
