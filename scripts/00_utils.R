# Shared helpers for 1M Care Conversations analysis scripts

# Reduce a column header to the words in it: lower case, straight quotes,
# plain hyphens, no punctuation, single spaces. Exports vary in spacing,
# curly apostrophes, and stray punctuation, and none of that can turn one
# question into another, so matching on this form is safe. A real rewording
# still needs a listed alias.
normalize_header <- function(x) {
  x |>
    stringr::str_to_lower() |>
    stringr::str_replace_all(c("’" = "'", "‘" = "'", "“" = "\"", "”" = "\"",
                               "—" = "-", "–" = "-")) |>
    stringr::str_replace_all("[^a-z0-9 ]+", " ") |>
    stringr::str_squish()
}

# Rename export columns (full question text) to short IDs, validating in both
# directions so an export with added, dropped, or reworded columns fails
# loudly. Each `col_map` entry is one or more accepted headers for that ID
# (the form's question wording was revised in Aug 2026, so a question can
# appear under either wording); headers are compared via normalize_header().
# IDs in `optional` may be absent (columns that vary across form versions,
# e.g. f1 dropped the address fields and added q4c). Column order is never
# used to assign names, but a change in the export's column order is worth
# knowing about, so it warns.
rename_validated <- function(data, col_map, optional = character()) {
  aliases <- purrr::imap(as.list(col_map), \(headers, id) {
    tibble::tibble(id = id, header = normalize_header(headers))
  }) |>
    purrr::list_rbind()
  collided <- aliases |>
    dplyr::distinct() |>
    dplyr::filter(duplicated(header) | duplicated(header, fromLast = TRUE))
  if (nrow(collided) > 0) {
    cli::cli_abort(c(
      "col_map lists the same header under more than one ID:",
      purrr::set_names(paste0(collided$id, ': "', collided$header, '"'), "x")
    ))
  }

  present <- tibble::tibble(original = names(data), header = normalize_header(names(data)))
  matched <- dplyr::inner_join(present, dplyr::distinct(aliases), by = "header")

  unmatched <- present$original[!present$header %in% aliases$header]
  missing   <- setdiff(setdiff(names(col_map), optional), matched$id)
  twice     <- unique(matched$id[duplicated(matched$id)])
  if (length(unmatched) > 0 || length(missing) > 0 || length(twice) > 0) {
    cli::cli_abort(c(
      "Column mismatch between export and col_map.",
      purrr::set_names(paste0('In export, not mapped: "', unmatched, '"'), "x"),
      purrr::set_names(paste0('Mapped, not in export: "', missing, '"'), "x"),
      purrr::set_names(paste0('Two headers in the export map to: "', twice, '"'), "x")
    ))
  }

  expected <- match(matched$id, names(col_map))
  if (is.unsorted(expected)) {
    moved <- matched$id[expected != sort(expected)]
    cli::cli_warn(
      "Export columns are in a different order than col_map (names are matched by header, so nothing is misassigned): {.val {moved}}"
    )
  }
  dplyr::rename(data, dplyr::all_of(purrr::set_names(matched$original, matched$id)))
}

# Split one multi-select cell into its selections. Two export formats exist:
# pipe-delimited ("a|b", most files) and comma-delimited ("a, b", the
# Aug 2026 f1 complete export). Commas also appear inside option text, so a
# comma-delimited cell is parsed by matching known options from the front,
# longest first; whatever remains unmatched is free text ("Other").
# Tokens are trimmed so "c | e" and "c|e" encode identically, and empty
# tokens (a stray trailing pipe) are dropped rather than counted as "other".
split_selections <- function(x, options) {
  if (is.na(x)) return(NA_character_)
  if (stringr::str_detect(x, stringr::fixed("|"))) {
    tokens <- stringr::str_trim(stringr::str_split_1(x, stringr::fixed("|")))
    return(tokens[tokens != ""])
  }
  known <- unlist(options)
  known <- known[order(-nchar(known))]
  out <- character()
  rest <- stringr::str_trim(x)
  while (nchar(rest) > 0) {
    hit <- known[startsWith(rest, known)]
    if (length(hit) == 0) {
      out <- c(out, rest)
      break
    }
    out <- c(out, hit[1])
    rest <- stringr::str_remove(stringr::str_sub(rest, nchar(hit[1]) + 1), "^\\s*,\\s*")
  }
  out
}

# One-hot encode a multi-select column (see split_selections) into one logical column
# per option (TRUE = selected, FALSE = saw the question but didn't select,
# NA = never saw it), plus `{col}_other`/`{col}_other_text` capturing anything
# not in the dictionary. `options` entries may be a single string or a vector
# of accepted wordings (aliases across form revisions) — any variant sets the
# same indicator. A free-text value repeating across 3+ respondents warns:
# repetition suggests a structured option missing from the dictionary.
encode_multiselect <- function(data, col, options) {
  # a wording listed under two options would silently set both indicators
  if (anyDuplicated(unlist(options)) > 0) {
    dup <- unlist(options)[duplicated(unlist(options))]
    cli::cli_abort("Duplicate wording{?s} across {.field {col}} options: {.val {dup}}")
  }

  selections <- purrr::map(data[[col]], split_selections, options = options)
  extras <- purrr::map(selections, \(s) s[!is.na(s) & s != "" & !s %in% unlist(options)])

  repeated <- table(unlist(extras)) |>
    purrr::keep(\(n) n >= 3) |>
    names() |>
    setdiff(c("Other", "true", "TRUE")) |>
    purrr::discard(\(v) stringr::str_starts(v, "Other:"))
  if (length(repeated) > 0) {
    cli::cli_warn(c(
      "Free-text value{?s} in {.field {col}} repeated across 3+ respondents — new structured option{?s} missing from the dictionary?",
      purrr::set_names(stringr::str_trunc(repeated, 70), "!")
    ))
  }

  indicators <- options |>
    purrr::map(\(opt) purrr::map_lgl(selections, \(s) any(s %in% opt))) |>
    purrr::set_names(stringr::str_c(col, "_", names(options))) |>
    tibble::as_tibble() |>
    dplyr::mutate(
      "{col}_other"      := purrr::map_lgl(extras, \(s) length(s) > 0),
      "{col}_other_text" := purrr::map_chr(extras, \(s) {
        s <- stringr::str_remove(s[!s %in% c("Other", "true", "TRUE")], "^Other:\\s*")
        if (length(s) > 0) stringr::str_flatten(s, collapse = " ; ") else NA_character_
      }),
      dplyr::across(
        tidyselect::where(is.logical),
        \(x) dplyr::if_else(is.na(data[[col]]), NA, x)
      )
    )

  data |>
    dplyr::select(-dplyr::all_of(col)) |>
    dplyr::bind_cols(indicators)
}

# Convert a single-select column to a factor with the questionnaire's level
# order, erroring on any value outside that set so reworded options in a new
# export surface immediately instead of becoming NA.
to_factor <- function(x, levels) {
  unknown <- setdiff(unique(x[!is.na(x)]), levels)
  if (length(unknown) > 0) {
    cli::cli_abort(c(
      "{length(unknown)} value{?s} outside the expected levels — add or fix:",
      purrr::set_names(unknown, rep("x", length(unknown)))
    ))
  }
  factor(x, levels = levels)
}

# Assign each respondent their single survey pathway from the encoded q1
# indicators. Priority current > past > future > observer verified
# empirically against which questions respondents were actually shown:
# receiving/needing care routes to current (path A, care recipient);
# observer-only completes all answered q2d; a past+future respondent was
# shown only the past questions.
derive_pathway <- function(data) {
  dplyr::mutate(
    data,
    pathway = dplyr::case_when(
      q1_child_now | q1_aging_now | q1_disability_now | q1_paid_provider |
        q1_need_care_now | q1_receives_care ~ "current",
      q1_cared_past ~ "past",
      q1_expect_future ~ "future",
      q1_observer ~ "observer",
      q1_none ~ "none"
    ) |>
      factor(levels = c("current", "past", "future", "observer", "none"))
  )
}

# Unique IDs export in scientific notation ("1.470978936E9"); normalize to
# plain digit strings so joins across exports are stable regardless of how a
# given file formats them. Errors on anything non-numeric or too long to
# represent exactly (doubles are exact to 15 significant digits) rather than
# passing a corrupted key downstream.
normalize_id <- function(x) {
  num <- suppressWarnings(as.numeric(x))
  out <- dplyr::if_else(
    is.na(x), NA_character_,
    format(num, scientific = FALSE, trim = TRUE)
  )
  bad <- !is.na(x) & (is.na(num) | nchar(out) > 15)
  if (any(bad)) {
    cli::cli_abort(
      "ID{?s} not exactly representable as plain digits: {.val {head(unique(x[bad]), 5)}}"
    )
  }
  out
}

# Compare each delivery's rows with what the team's DATA LOG says the file
# covers: submission dates inside the logged collection window (one day of
# slack for timezone) and respondent IDs inside the logged first-last range.
# Returns one row per delivery with the check results; warns on any failure.
# `data` needs `delivery`, `submitted_at` (POSIXct), and `respondent_id`
# (digit strings); `deliveries` is data/raw/deliveries.csv.
check_against_log <- function(data, deliveries, label) {
  checks <- data |>
    dplyr::mutate(day = as.Date(submitted_at), id = suppressWarnings(as.numeric(respondent_id))) |>
    dplyr::summarise(
      rows = dplyr::n(),
      first_day = min(day, na.rm = TRUE), last_day = max(day, na.rm = TRUE),
      min_id = min(id, na.rm = TRUE), max_id = max(id, na.rm = TRUE),
      .by = delivery
    ) |>
    dplyr::inner_join(
      dplyr::select(deliveries, delivery = file, collection_start, collection_end, first_id, last_id),
      by = "delivery"
    ) |>
    dplyr::mutate(
      dates_ok = is.na(collection_start) |
        (first_day >= collection_start - 1 & last_day <= collection_end + 1),
      ids_ok = is.na(first_id) | is.na(last_id) | (min_id >= first_id & max_id <= last_id)
    )
  bad <- dplyr::filter(checks, !dates_ok | !ids_ok)
  if (nrow(bad) > 0) {
    cli::cli_warn(c(
      "{label}: {nrow(bad)} deliver{?y/ies} outside what the DATA LOG says {?it covers/they cover}:",
      purrr::set_names(paste0(
        bad$delivery, " — rows ", bad$first_day, " to ", bad$last_day,
        " (log: ", bad$collection_start, " to ", bad$collection_end, "); IDs ",
        format(bad$min_id, scientific = FALSE), "-", format(bad$max_id, scientific = FALSE),
        " (log: ", format(bad$first_id, scientific = FALSE), "-", format(bad$last_id, scientific = FALSE), ")"
      ), "!")
    ))
  }
  checks
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
