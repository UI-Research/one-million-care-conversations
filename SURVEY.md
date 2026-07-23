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
  questions; verified against 327 real completes (every complete answers
  exactly its pathway's questions).
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

## Known gaps and open questions

- **Open-text questions (q5a/q5c/q5d, q7) are not in the closed exports** —
  they come as a separate `*_opentext` export (f0 test version received;
  respondent IDs match the closed export, so they join on `Unique ID`).
- The canvassing form embeds this same battery behind a doorstep funnel
  (approach → engaged → care-connection screener → full questions), with
  canvasser-only fields (mode, short-label challenges, canvasser ZIP). No
  demographics, no respondent ZIP. Only the f0 test delivery exists so far.
- Timezone of `Time`, partial→complete ID behavior, and the exact trigger
  wording for f-version changes are unconfirmed with CAG.
- Not yet received in any form: real canvassing, interviews, pre-survey
  survey.
