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
**one pathway** (with one observed exception, below), then everyone converges
on q6 (ideal care) and demographics.

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
  Respondents selecting `paid_provider` + `cared_past` (16 completes and 1
  partial as of the Aug 12 deliveries) answered the current *and* past
  questions — the only cross-pathway pattern. `derive_pathway()` still
  labels them `current`; the skip-logic check warns on them. Routing rule
  unconfirmed with CAG. Separately, one or two *partials* whose q1 is `none`
  answered other pathways' questions — looks like a form glitch or a test;
  worth asking CAG.
- **Care recipients route to current**: the q1 options "I need care but am not
  receiving it" and "I receive or have received care..." lead to q2a, not a
  separate track.
- Question numbering mnemonic: q2x = challenges, q3x = ideal supports,
  q4x = who helps (x = pathway letter); q5x = open text; q6/q7 shared.

## Export behavior

- **Column names are the full question text**, which changes across form
  versions — the cleaning script validates exact matches and fails loudly.
- **Multi-selects are pipe-delimited** in one cell, in survey option order —
  except the `nopii_surv_export_20260710-20260812_f1_complete_closed` delivery
  (received Sept 2026), which came through a different export path:
  timestamp column named `Date submitted` (same Excel serials), multi-selects
  **comma-separated** (ambiguous, since option text contains commas — the
  cleaning parses known options from the front), and en-/em-dashes and curly
  apostrophes where other files have hyphens and straight quotes
  (`$25,000–$49,999`, `Affordable — without…`, `I don’t`).
  `split_selections()` in `00_utils.R` handles both formats; punctuation is
  normalized at read time. Ask CAG which export route this was.
- **"Other" is open form** and exports three ways: `"Other: <text>"`, bare
  `"Other"`/`"true"` (checkbox without text), or raw free text with no prefix.
  Cleaning captures all of it in `*_other`/`*_other_text` columns.
- **q6 "choose up to three" is not enforced by the live form.** Roughly 40%
  of respondents who answered q6 chose more than three; a noticeable share
  chose all eleven (bursts in the weeks of June 14 and July 19, across
  channels).
  Cleaning keeps every selection; the chartbook reports q6 shares both
  overall and among those who kept to three. Which to headline is a research
  decision to settle with CAG.
- **Free text containing a vertical bar** would be split at the bar like a
  multi-select, since the export uses `|` as the separator. Not observed so
  far; a fragment would show up as extra `_other_text` pieces.
- **Datetimes arrive as Excel serials** (day fractions); timezone unconfirmed.
- **Numeric-looking text picks up float artifacts**: hh_size `"4.0"`, zip
  `"91401.0"` (348 of 485 f1 rows; stripped in cleaning). A few respondents
  enter ZIP+4 (`"89142-1703"`) — flagged by the ZIP check, kept verbatim.
- **`Unique ID` exports in scientific notation** (`"1.470978936E9"`) — exact
  at 10 digits. Cleaning normalizes IDs to plain digit strings
  (`normalize_id()` in `00_utils.R`); apply the same normalization when
  joining any raw export (e.g. the open-text files).
- **Complete and partial responses come in separate files with different ID
  schemes** (~1.47e9 vs ~4.0e7 ranges). No ID appears in both, but whether a
  partial that later completes is re-delivered as a new complete ID is
  **unknown** — worth asking CAG before longitudinal claims.
- The `* DATA LOG *.xlsx` in the delivery folder is the team's manifest: test
  vs real activity, PII-skim flag, ID ranges, source links.
  `scripts/00_ingest-raw.R` validates every sync against it.

## Form versions

| | f0 (test, June 2–8) | f1 (real, June 4+) |
|---|---|---|
| Status | pre-launch test, excluded from cleaning | first real delivery |
| Address/City/State columns | present (empty) | removed (their column-omission automation) |
| q4c (who helped, past) | missing | present |
| q1 options | 7 observed | 10 (adds recipient ×2 + observer) |
| hh_size format | `"4"` | `"4.0"` |

- **f-numbers are distribution channels, not questionnaire revisions**
  (confirmed by CAG via Jaimie/Teresa, Aug 27 2026). Per Teresa: "All Survey
  files are the same survey" — keep `form_version` as a source variable.
  Authoritative mapping, with the exact Formstack form names (Jaimie, Aug 27
  and Sept 2026):

  | | Survey — Formstack name | Notes |
  |---|---|---|
  | f1 | 1 Million Care Conversations Survey - May 29 2026 | launch link |
  | f2 | 1 Million Care Conversations Survey - July 21 2026 - Virtual Day of Action | second link to stay under Formstack's 100k response limit |
  | f3 | 1 Million Care Conversations Survey - Postcards | QR code offered after a canvass |
  | f4 | 1 Million Care Conversations Survey - E-mail Opt-In | |
  | f5 | 1 Million Care Conversations Survey - Spanish | CAG translates responses to English before delivery; methodological implications TBD |
  | f6 | 1 Million Care Conversations Survey - Take Me Home Screenings | film screenings in several cities (added Aug 27) |

  | | Canvass — Formstack name |
  |---|---|
  | f1 | 1 Million Care Conversations - Canvass Launch |
  | f2 | 1 Million Care Conversations - Canvass at Daisy Chain - 92618-Other In Person-No Survey Add-On |

  Delivered so far: survey f1/f2/f3/f4/f6 (closed + open-text; f4 and f6
  first delivered 2026-09-22 covering August), canvass f1 and c1–c3. Not
  yet: survey f5 (Spanish). Per Teresa (2026-09-22) CAG will send survey and
  canvass data **no more than once a month**; transcripts may come sooner.
- **Canvass forms are numbered `c1`, `c2`, `c3` from the Sept 2026
  deliveries** (earlier files of the same launch form said `f1`; cleaning
  maps canvass `f1` → `c1`). These are a **revised instrument**: the
  care-connection screener and doorstep checklist are replaced by
  "1. Do you need care or is there someone in your life you help take care
  of…" and an open-text "2. What's been hard about that?" (delivered inside
  the *closed* export). Column sets differ by form (c2 = only those two
  questions; c3 = canvasser fields + the two questions, no battery; `c3`
  not in CAG's form table). Cleaned into its own file
  (`canvassing_revised_clean`) and reported separately in the chartbook;
  how (or whether) the two forms combine is still open — issue #12.
- **Delivery file-name drift seen so far** (all handled by the file-selection
  patterns in `01_clean-data.qmd` and the name normalization in
  `00_ingest-raw.R`): trailing underscore padding (`_____`), a space before
  the extension (`_closed .xlsx`), `_opentext` → `_open`, uppercase form
  number (`F1`), and a `nopii_` prefix from Aug 2026 on. The DATA LOG can
  also list several files in one cell on separate lines.
  f0 (both tools) was the pre-launch test — a *revision* lineage, unlike
  f1–f6 which share one instrument.
- **Aug 19 2026 wording revision** ("NEW 1MCC Digital Survey Questions -
  August 19 2026" PDF): four options reworded (q2a `finding`; q6
  `easy_to_use`, `lived_experience`, `healthy_dev`). Per Teresa (email
  2026-08-26) old and new wording are **combined** — the dictionaries in
  `01_clean-data.qmd` list both variants as aliases mapping to the same
  indicator. **The question text changed too**, contrary to the earlier
  reading of the PDF: exports covering Aug 2026 on (f2 Aug, f4, f6) carry
  rewritten headers for nine questions — q1 "Care and caregiving look
  different for everyone. Choose all that apply to you."; q2a "What's been
  hard?"; q3a "What help would make a difference for you or the people you
  care for?"; q2b "What do you think will be hard in the future?"; q3b "What
  help would make a difference?"; q2c "What was hard?"; q3c "What help would
  have made difference for you or people around you?" (sic); q2d "What's been
  hard for the people you know?"; q3d "What help would make a difference for
  the people you know?" — all "(Choose all that apply)". q4a/q4c/q4d, q6, and
  demographics unchanged. `col_map` lists both headers per question;
  `rename_validated()` accepts either (whitespace-collapsed, since one file
  had a double space). Answer options under the new headers are unchanged
  (no drift alarms). A file can mix bar- and comma-separated cells. Since f-numbers are channels, the revision presumably edits the
  live forms in place — so **wording eras are split by `submitted_at`
  (before/after 2026-08-19), not by `form_version`**. New variants are seeded
  from the PDF (hyphen formatting per observed exports) and not yet confirmed
  against a real export. The PDF also confirms q4d includes `employer` and
  `no_help` (unobserved so far) and shows an income option typo
  ("$150,00 - $174,999") — unconfirmed whether it's in the live form.
- **Deliveries from Aug 2026 carry a `nopii_` filename prefix** (PII-skimmed
  upstream). File discovery in `01_clean-data.qmd` accounts for every file in
  the mirror — claimed, known set-aside, or loud error — so naming drift
  (which has happened repeatedly: trailing underscores/spaces,
  `_opentext` → `_open`) can never silently drop a delivery.

## Known gaps and open questions

- **Open-text questions (q5a/q5c/q5d, q7) are not in the closed exports** —
  they come as separate `*_opentext`/`*_open` exports whose respondent IDs
  match the paired closed export, so they join on `Unique ID` (after
  `normalize_id()`).
- The canvassing form embeds this same battery behind a doorstep funnel
  (approach → engaged → care-connection screener → full questions), with
  canvasser-only fields (mode, short-label challenges, canvasser ZIP). No
  demographics, no respondent ZIP. Real `f1` deliveries (June 9+, integrated
  Aug 2026) are column-identical to the f0 test; the f1 form added two
  doorstep options ("Availability", "Hard to figure out"). One f1 partial
  answered the battery despite declining to continue (funnel check warns).
- Timezone of `Time` and partial→complete ID behavior are unconfirmed with
  CAG.
- Set aside for the text-analysis pipeline (received Aug 2026, not read by
  the cleaning script): survey f1/f2/f3 and canvassing open-text exports (two
  columns share the identical q5 header — pathway mapping unconfirmed) and
  the pre-launch "One Question Poll" (everyaction) export. Note the naming
  drift: newer open-text files are suffixed `_open` rather than `_opentext`.
- **"One Question Poll"** (Teresa's deliberate label; aka pre-launch survey /
  EveryAction): one open question from a March 2026 screening event, link
  partially reused after. CAG may revive/revise it (add to canvas/survey,
  make it multiple-choice, blast wider) — how it fits the analysis is TBD
  until they decide. Keep it strictly separate from the 16+ survey files.
- **Expected but not yet delivered**: survey f4 (E-mail Opt-In), f5 (Spanish
  — English translations required before delivery), f6 (film screenings),
  canvass f2 (Daisy Chain event); interviews (short and long form). CAG also
  reports the canvass open-text question exists but has no answers yet.
- **~22 file types arrive monthly** (tools × form × closed/open ×
  complete/partial). Rob is helping CAG automate: up to 4 of the 22 may
  become daily-updating Google Sheets readable directly from R — would slot
  into the ingest layer as an alternate transport if it materializes.
- **Urban/rural**: the chartbook joins respondent ZIP to USDA ERS 2020 RUCA
  codes (ZIP file, Sept 2025 release; 786 of 790 ZIPs match) and reports a
  4-way (metro / micropolitan / small town / rural) and 2-way (RUCA 1–3 vs
  4–10) split. Still planned: sensitivity to the collapse choice, demographic
  comparison against a national benchmark, interview-mention concordance.
- Canvassing complete files use 10-digit survey-style IDs while partial files
  use 8-digit IDs (two export mechanisms?) — cross-space duplicates are
  undetectable; parked pending a CAG answer.
