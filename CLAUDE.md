# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

R/Quarto analysis code for the Urban Institute × Caring Across Generations "1M Conversations About Care" initiative: cleaning and analyzing survey and canvassing data about care challenges and supports. Only analysis code lives here — data and project documents live on Box.

## Commands

```sh
Rscript scripts/00_ingest-raw.R            # sync data/raw/ from Box via API (needs box_auth() + BOX_RAW_FOLDER_ID in ~/.Renviron)
quarto render scripts/01_clean-data.qmd    # clean raw exports → data/processed/ + data dictionary
quarto render scripts/survey/01_chartbook.qmd  # preliminary chartbook (reads processed data)
```

Run 00 to pull new deliveries (it aborts on Box↔DATA-LOG mismatches, upstream file modifications, and un-PII-skimmed deliveries — resolve with the team, don't bypass), then 01 before the chartbook. Only 00 touches Box; rendering works offline from the local copy. There is no build system, test suite, or renv — packages (tidyverse, readxl, here, cli, urbnthemes, reactable) come from the system library. The chartbook downloads the USDA ERS RUCA ZIP-code file into `data/raw/reference/` on first render (state + rurality lookup). All paths use `here()`, so rendering works from any directory.

The rendered qmds are read by the research lead (a PhD, not a data scientist): prose explains each step in plain language before its chunk, code is folded, and purely mechanical chunks (setup, writes) are hidden. Keep that register when editing them.

## Hard rules

- **No PII, no coalition data in the repo — ever.** `.gitignore` blocks all of `data/` except the generated `data-dictionary.csv` (schema only), plus `.pdf`/`.docx`. Rendered `.html` under `scripts/` IS committed (Manu's decision, 2026-09-17): keep rendered output to aggregates — no respondent IDs, ZIPs, or free text in printed output. If the PII guard in `01_clean-data.qmd` trips (non-empty address fields), stop and flag it — do not work around it.
- Coalition-collected data must never be described as "nationally representative" in any Urban output.

## Architecture

Pipeline: `scripts/00_ingest-raw.R` (Box API sync by file ID; writes `data/raw/box-manifest.csv` with sha1s for change detection) → `data/raw/Raw data backups/` (untouched mirror of the Box delivery folder) → `scripts/01_clean-data.qmd` → `data/processed/` (`survey_clean.rds/.csv`, `canvassing_clean.rds/.csv`, `data-dictionary.csv`) → `scripts/survey/01_chartbook.qmd` (issue #1: counts by state and tool, demographics, selection rates). Shared helpers live in `scripts/00_utils.R`, sourced by both qmds. `scripts/nlp/` holds the LLM transcript-coding pipeline and its review dashboard.

Key design decisions that span files:

- **Fail loudly on export drift.** Export column names are the full question text. `rename_validated()` (00_utils.R) errors on any unmapped or missing column. `encode_multiselect()` routes unknown option values to `{q}_other` and warns when a free-text value repeats across 3+ respondents (likely a new structured option — the warnings in the rendered output are monitored drift alarms, not noise). Single-selects error outright via `to_factor()`. When these fire, the fix is to deliberately update the `col_map` / option dictionaries in `01_clean-data.qmd`, not to relax the validation.
- **Option dictionaries use observed export text, not the questionnaire PDF**, and an option may list several accepted wordings (aliases) when the live form is reworded — all variants set the same indicator column. The live form's wording diverges from the official documents. `SURVEY.md` is the reference for the instrument as it actually behaves (routing, form versions/channels, export quirks) — read it before touching cleaning code, and update it when new empirical facts about the instrument are established.
- **Multi-select encoding semantics.** Each multi-select question becomes one logical column per option (`q2a_unaffordable`, …): `TRUE` = selected, `FALSE` = saw the question but didn't select, `NA` = never saw it (skip logic) or skipped. Selection rates are `mean(x, na.rm = TRUE)`. Anything not in the option dictionary lands in `{q}_other` / `{q}_other_text` (respondent voice, feeds the NLP work).
- **Pathways.** Respondents route down one of five pathways (current/past/future/observer/none) from q1, with priority current > past > future > observer — `derive_pathway()` in 00_utils.R encodes this, verified empirically (one known exception: paid providers with past experience answer two batteries; see SURVEY.md). Skip-logic checks in 01 validate that respondents answered their pathway's questions.
- **Wide is canonical, long is for plotting.** The processed files are one row per respondent; `pivot_selections()` produces the respondent × option long view at the top of summary/plotting code.
- **Two export formats exist.** Most files are pipe-delimited with plain punctuation; the Aug 2026 f1 complete export is comma-delimited with en/em-dashes, curly apostrophes, and a `Date submitted` header. `split_selections()` (00_utils.R) parses both; `read_delivery()` normalizes punctuation and header aliases. Expect more variants — extend those two places, not the dictionaries.
- **Branches are `iss<n>`** for issue n; PRs close the issue. The rendered site (`docs/`, from `quarto render` at the root) and `_freeze/` are committed. The coding dashboard is a site resource built into `coding-dashboard/` by `scripts/nlp/coding_dashboard.R` (no more gh-pages deploy ritual).
- **Every mirrored file is accounted for.** Delivery filenames encode source (`surv`/`canv`), dates, form number (a distribution *channel*, not a revision — see SURVEY.md), closed vs open-text, and complete vs partial. The read chunk in 01 assigns every file one fate — claimed by a cleaning section, known set-aside (f0 tests, open-text, everyaction), or a loud error — so naming drift can't silently drop a delivery. Nothing in `data/raw/` is renamed by hand; `* DATA LOG *.xlsx` is the team's delivery manifest and `00_ingest-raw.R` validates each sync against it.
- f0 test deliveries are excluded from both tools; all real channels (`f1`+) are cleaned. 02 keeps survey and canvassing separate and never pools them. The open-text and everyaction exports are set aside for the NLP pipeline and not read by 01.
