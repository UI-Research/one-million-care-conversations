# Shared helpers for 1M Care Conversations analysis scripts

# Rename export columns (full question text) to short IDs, validating in both
# directions so an export with added/dropped/reworded columns fails loudly.
rename_validated <- function(data, col_map) {
  unmatched <- setdiff(names(data), col_map)
  missing   <- setdiff(col_map, names(data))
  if (length(unmatched) > 0 || length(missing) > 0) {
    cli::cli_abort(c(
      "Column mismatch between export and col_map.",
      purrr::set_names(paste0('In export, not mapped: "', unmatched, '"'), "x"),
      purrr::set_names(paste0('Mapped, not in export: "', missing, '"'), "x")
    ))
  }
  dplyr::rename(data, dplyr::all_of(col_map))
}

# Assign each respondent their single survey pathway from the encoded q1
# indicators. Priority current > past > future verified empirically: a test
# respondent eligible for both past and future was shown only the past (q2c)
# questions. "observer" is reserved for the know-someone q1 option, which has
# not yet appeared in the data.
derive_pathway <- function(data) {
  dplyr::mutate(
    data,
    pathway = dplyr::case_when(
      q1_child_now | q1_aging_now | q1_disability_now | q1_paid_provider ~ "current",
      q1_cared_past ~ "past",
      q1_expect_future ~ "future",
      q1_none ~ "none"
    ) |>
      factor(levels = c("current", "past", "future", "observer", "none"))
  )
}

# Sheets read as all-text leave Excel datetimes as day-fraction serial numbers
excel_datetime <- function(x, tz = "UTC") {
  as.POSIXct(round(as.numeric(x) * 86400), origin = "1899-12-30", tz = tz)
}

# Pivot the wide one-row-per-respondent indicators into a long view with one
# row per respondent x option: `question` ("q2a"), `option` ("unaffordable"),
# and logical `selected`. Respondent-level columns (id, demographics) carry
# along on every row, which is the shape ggplot/count() want. The wide file is
# canonical; use this at the top of plotting/summary code.
pivot_selections <- function(data) {
  data |>
    tidyr::pivot_longer(
      tidyselect::where(is.logical),
      names_to = c("question", "option"),
      names_pattern = "^([^_]+)_(.*)$",
      values_to = "selected"
    )
}
