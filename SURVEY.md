# The 1MCC survey, as observed in the data

Reference notes on the survey instrument as it actually behaves in the
exports — routing, form versions, and known divergences. The **official
questionnaire documents live on Box** ("Official Conversation Tool Questions"
folder); per-column option text is in `data/processed/data-dictionary.csv`.
This file covers what neither of those tells you.

**Rule of thumb: trust the data, not the questionnaire PDF.** The live form's
wording differs from the official documents in many places (e.g. the PDF's
"Caring for a child/children" is "I care for a child or children now" in
exports; em-dashes become hyphens; some option sets are merged or reworded).
All dictionaries in `scripts/01_clean-data.qmd` use observed export text.

## Structure and routing

Respondents answer q1 (connection to care, multi-select), get routed down
**exactly one pathway**, then everyone converges on q6 (ideal care) and
demographics.

| Pathway | q1 trigger | Questions shown |
|---|---|---|
| A `current` | cares for child/aging/disabled person now, paid care worker, **needs or receives care** | q2a, q3a, q4a, (q5a) |
| C `past` | cared for someone in the past | q2c, q3c, q4c, (q5c) |
| B `future` | expects to need/give care | q2b, q3b |
| D `observer` | knows someone who receives/needs care | q2d, q3d, q4d, (q5d) |
| E `none` | none of these apply | straight to q6 |

Routing facts established empirically (not stated in any document):

- **Priority when multiple triggers apply: current > past > future > observer
  > none.** A respondent eligible for past *and* future is shown only the past
  questions; verified against 327 real completes.
- **Exception: paid providers with past experience answer both batteries.**
  The 4 completes selecting exactly `paid_provider` + `cared_past` (3 f1, 1 f3)
  answered the current *and* past questions (the only observed cross-pathway
  completes). `derive_pathway()` still labels them `current`; the skip-logic
  check warns on them. Routing rule unconfirmed with CAG.
- **Care recipients route to current**: the q1 options "I need care but am not
  receiving it" and "I receive or have received care..." lead to q2a, not a
  separate track.
- Question numbering mnemonic: q2x = challenges, q3x = ideal supports,
  q4x = who helps (x = pathway letter); q5x = open text; q6/q7 shared.

## Export behavior

- **Column names are the full question text**, which changes across form
  versions — the cleaning script validates exact matches and fails loudly.
- **Multi-selects are pipe-delimited** in one cell, in survey option order.
- **"Other" is open form** and exports three ways: `"Other: <text>"`, bare
  `"Other"`/`"true"` (checkbox without text), or raw free text with no prefix.
  Cleaning captures all of it in `*_other`/`*_other_text` columns.
- **Datetimes arrive as Excel serials** (day fractions); timezone unconfirmed.
- **Numeric-looking text picks up float artifacts**: hh_size `"4.0"`, zip
  `"91401.0"` (348 of 485 f1 rows; stripped in cleaning). A few respondents
  enter ZIP+4 (`"89142-1703"`) — flagged by the ZIP check, kept verbatim.
- **`Unique ID` exports in scientific notation** (`"1.470978936E9"`) — exact
  at 10 digits, but join keys must come from the same export style.
- **Complete and partial responses come in separate files with different ID
  schemes** (~1.47e9 vs ~4.0e7 ranges). No ID appears in both, but whether a
  partial that later completes is re-delivered as a new complete ID is
  **unknown** — worth asking CAG before longitudinal claims.
- The `_ DATA LOG _.xlsx` in the delivery folder is the manifest: test vs real
  activity, PII-skim flag, ID ranges, source links.

## Form versions

| | f0 (test, June 2–8) | f1 (real, June 4+) |
|---|---|---|
| Status | pre-launch test, excluded from cleaning | first real delivery |
| Address/City/State columns | present (empty) | removed (their column-omission automation) |
| q4c (who helped, past) | missing | present |
| q1 options | 7 observed | 10 (adds recipient ×2 + observer) |
| hh_size format | `"4"` | `"4.0"` |

- **f3 = "Survey Postcards"** (per the data log; deliveries from Jul 31 2026):
  a postcard-channel copy of the f1 form — all 23 columns word-for-word
  identical to f1. No f2 has been delivered; what increments the f-number is
  unconfirmed with CAG, so treat it as a categorical label, not a timeline.
- **Aug 19 2026 digital-form revision** ("NEW 1MCC Digital Survey Questions -
  August 19 2026" PDF; f-number unknown until the first delivery): question
  text unchanged, four options reworded (q2a `finding`; q6 `easy_to_use`,
  `lived_experience`, `healthy_dev`). Per Teresa (email 2026-08-26) old and
  new wording are **combined** — the dictionaries in `01_clean-data.qmd` list
  both variants as aliases mapping to the same indicator. New variants are
  seeded from the PDF (hyphen formatting per observed exports) and not yet
  confirmed against a real export. The PDF also confirms q4d includes
  `employer` and `no_help` (unobserved so far) and shows an income option typo
  ("$150,00 - $174,999") — unconfirmed whether it's in the live form.
- **Deliveries from Aug 2026 carry a `nopii_` filename prefix** (PII-skimmed
  upstream); file discovery accepts it and aborts on unclaimed exports.

## Known gaps and open questions

- **Open-text questions (q5a/q5c/q5d, q7) are not in the closed exports** —
  they come as a separate `*_opentext` export (f0 test version received;
  respondent IDs match the closed export, so they join on `Unique ID`).
- The canvassing form embeds this same battery behind a doorstep funnel
  (approach → engaged → care-connection screener → full questions), with
  canvasser-only fields (mode, short-label challenges, canvasser ZIP). No
  demographics, no respondent ZIP. Real `f1` deliveries (June 9+, integrated
  Aug 2026) are column-identical to the f0 test; the f1 form added two
  doorstep options ("Availability", "Hard to figure out"). One f1 partial
  answered the battery despite declining to continue (funnel check warns).
- Timezone of `Time`, partial→complete ID behavior, and the exact trigger
  wording for f-version changes are unconfirmed with CAG.
- Set aside for the text-analysis pipeline (received Aug 2026, not read by
  the cleaning script): `f1` survey and canvassing open-text exports (two
  columns share the identical q5 header — pathway mapping unconfirmed) and
  the pre-launch "One Question Poll" (everyaction) export.
- Canvassing complete files use 10-digit survey-style IDs while partial files
  use 8-digit IDs (two export mechanisms?) — cross-space duplicates are
  undetectable; parked pending a CAG answer.
