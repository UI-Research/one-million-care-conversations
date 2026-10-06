# Gather every open-ended answer into one long file for coding:
# data/processed/open_ended.csv with one row per answer.
#
# Sources (all set aside by the cleaning step, read here instead):
#   survey *_open / *_opentext exports: q5 (how supports helped; one column per
#     pathway, two of them under the SAME header, so columns are taken by
#     position), q7 (what could become possible)
#   canvassing c2 *_open exports: Q3 "one thing you would change about care"
#   pre-launch poll (everyaction): "if money was not an issue ... change one thing"
#   revised-canvassing closed files: Q2 "what's been hard about that" (free text
#     delivered inside the closed export; already in canvassing_revised_clean)
#
# Survey answers are joined to the closed file by respondent ID to carry the
# pathway, form, and status; the two same-header q5 columns are checked against
# the pathway (current -> q5a, past -> q5c).

library(tidyverse)
library(readxl)
library(here)
source(here("scripts/00_utils.R"))

raw_dir <- here("data/raw/Raw data backups")
deliveries <- read_csv(here("data/raw/deliveries.csv"), show_col_types = FALSE)
survey <- read_clean("survey") |> select(respondent_id, form_version, response_status, pathway)
canvassing_revised <- read_clean("canvassing_revised")

read_text_export <- function(file) {
  # two q5 columns share one header; "unique" repair suffixes the repeat
  # ("...3") so the frame is usable, and the prefix match below still finds it
  read_excel(file.path(raw_dir, file), col_types = "text", .name_repair = "unique_quiet") |>
    mutate(across(everything(), \(x) na_if(str_squish(x), ""))) |>
    mutate(delivery = file)
}

# ---- survey q5 / q7 ---------------------------------------------------------

survey_files <- deliveries |> filter(tool == "survey", content == "open", !test) |> pull(file)

survey_open <- map(survey_files, \(f) {
  x <- read_text_export(f)
  headers <- names(x)
  q5_cols <- which(str_detect(headers, "^How (did|do) these people or supports help"))
  q7_col  <- which(str_detect(headers, "^What could become possible"))
  id_col  <- which(headers == "Unique ID")
  stopifnot(length(q5_cols) == 3, length(q7_col) == 1, length(id_col) == 1)
  # export order follows the questionnaire: q5a (current), q5c (past), q5d (observer)
  tibble(
    delivery = f,
    respondent_id = normalize_id(x[[id_col]]),
    q5a = x[[q5_cols[1]]], q5c = x[[q5_cols[2]]], q5d = x[[q5_cols[3]]], q7 = x[[q7_col]]
  )
}) |>
  list_rbind() |>
  pivot_longer(c(q5a, q5c, q5d, q7), names_to = "question", values_to = "text") |>
  filter(!is.na(text)) |>
  left_join(survey, by = join_by(respondent_id)) |>
  mutate(tool = "survey")

# a q5 answer should sit in the column for the respondent's pathway
expected_q5 <- c(current = "q5a", past = "q5c", observer = "q5d")
q5_mismatch <- survey_open |>
  filter(str_starts(question, "q5"), !is.na(pathway)) |>
  filter(question != coalesce(expected_q5[as.character(pathway)], question))
if (nrow(q5_mismatch) > 0) {
  cli::cli_warn("{nrow(q5_mismatch)} q5 answer{?s} in a column that does not match the respondent's pathway (paid-provider double routing accounts for some)")
}
unmatched <- survey_open |> filter(is.na(pathway) & is.na(form_version))
if (nrow(unmatched) > 0) {
  cli::cli_warn("{nrow(unmatched)} survey answer{?s} whose respondent ID is not in the closed file")
}

# ---- canvassing c2 Q3 and revised-form Q2 -----------------------------------

canvass_open <- deliveries |> filter(tool == "canvass", content == "open", str_starts(form, "c"), !test) |> pull(file) |>
  map(\(f) {
    x <- read_text_export(f)
    col <- which(str_detect(names(x), "one thing you would change"))
    stopifnot(length(col) == 1)
    tibble(delivery = f, respondent_id = normalize_id(x[["Unique ID"]]), question = "canvass_q3", text = x[[col]])
  }) |>
  list_rbind() |>
  filter(!is.na(text)) |>
  mutate(tool = "canvassing", form_version = str_extract(delivery, "c\\d"), response_status = str_extract(delivery, "complete|partial"))

canvass_hard <- canvassing_revised |>
  filter(!is.na(hard_text)) |>
  transmute(delivery, respondent_id, question = "canvass_q2_hard", text = hard_text,
            tool = "canvassing", form_version, response_status)

# ---- pre-launch poll ---------------------------------------------------------

poll <- deliveries |> filter(tool == "poll") |> pull(file) |>
  map(\(f) {
    x <- read_text_export(f)
    col <- which(str_detect(names(x), "If money was not an issue"))
    stopifnot(length(col) == 1)
    tibble(delivery = f, respondent_id = NA_character_, question = "poll_change_one_thing", text = x[[col]],
           tool = "pre-launch poll", form_version = NA_character_, response_status = NA_character_)
  }) |>
  list_rbind() |>
  filter(!is.na(text))

# ---- assemble ----------------------------------------------------------------

question_text <- c(
  q5a = "How did these people or supports help, and what made the biggest difference? (current pathway)",
  q5c = "How did these people or supports help, and what made the biggest difference? (past pathway)",
  q5d = "How do these people or supports help, and what makes the biggest difference? (observer pathway)",
  q7  = "What could become possible if everyone had this support? How would it help you, your family, or your neighbors?",
  canvass_q3 = "What's one thing you would change about care?",
  canvass_q2_hard = "What's been hard about that?",
  poll_change_one_thing = "If money was not an issue, and you could change one thing about how care works in our country, what would it be?"
)

open_ended <- bind_rows(survey_open, canvass_open, canvass_hard, poll) |>
  mutate(
    question_text = question_text[question],
    pathway = as.character(pathway),
    answer_id = str_c(tool, "_", question, "_", coalesce(respondent_id, str_c("row", row_number())))
  ) |>
  select(answer_id, tool, question, question_text, text, respondent_id, pathway, form_version, response_status, delivery) |>
  arrange(tool, question, respondent_id)

write_csv(open_ended, here("data/processed/open_ended.csv"))
cli::cli_inform("Wrote {nrow(open_ended)} open-ended answers to data/processed/open_ended.csv")
print(count(open_ended, tool, question, name = "answers"))
