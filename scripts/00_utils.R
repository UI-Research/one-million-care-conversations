# Shared helpers for 1M Care Conversations analysis scripts

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
