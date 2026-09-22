# One Million Conversations About Care

## Admin
* [Box folder](https://urbanorg.app.box.com/folder/380112819949?s=yvq09wjknwclk6apl3jdtfvvuc9ua31e) (project documents and data deliveries)
* **Contact**: Manuel Alcalá Kovalski (data science), Teresa Kroeger (research lead)
* **Project code**: 103682-0001-001-00001-1M

## Project overview
The **1M Conversations About Care** (1MCC) initiative, led by [Caring Across Generations](https://caringacross.org/) (CAG), aims to shift how the country talks about caregiving: from care as an individual challenge to care as a shared one with shared stakes, and from a broken system to one where real choices are possible. Through a digital survey, doorstep canvassing, and interviews, it is engaging one million working- and middle-class families about their caregiving challenges, their vision for a future where care is supported well, and the policies that could make that vision real. The result is both an organizing effort and a knowledge base for a future policy vision.

The Urban Institute (WorkRise) is the research partner: it brings rigor to that sense-making by turning the patterns and themes in what families say into evidence that can anchor policy design, and by showing how those patterns vary across populations and places. This repository holds the analysis code for that work: cleaning the coalition's data deliveries, producing descriptive summaries, and the text-analysis pipeline for interviews and open-ended answers. The rendered documents are published as a website (see below).

[SURVEY.md](SURVEY.md) documents the survey instrument as it actually behaves in the data: routing, distribution channels, export quirks, and known open questions. Read it before touching the cleaning code.

> [!IMPORTANT]
> **No personal information and no respondent data in this repository.** Coalition data shared with Urban must contain no PII (the data collection is not IRB-approved, so this is legally non-negotiable), and only the generated `data-dictionary.csv` is committed under `data/`. Rendered HTML documents are committed because they show aggregates only.
>
> **"Nationally representative" is off limits.** From the scope of work: limitations of the data-collection methodology mean none of the data can be referred to as "nationally representative," and no Urban-authored publication relying on coalition-collected data will refer to it that way.

## Repo structure
```
├── README.md
├── SURVEY.md                 <- The survey instrument as observed in the data
├── data/
│   ├── raw/
│   │   ├── box-manifest.csv        <- What was fetched from Box (file IDs, checksums)
│   │   ├── deliveries.csv          <- One row per file: what the DATA LOG says it is
│   │   ├── Raw data backups/       <- Mirror of the Box delivery folder, incl. the DATA LOG
│   │   ├── interview-transcripts/  <- Interview transcripts pulled from Box
│   │   └── reference/              <- Lookups: RUCA codes and ACS figures downloaded on first render; care-policy grades entered by hand
│   └── processed/                  <- Cleaned outputs; only data-dictionary.csv is committed
│       └── interview-coding/       <- LLM-coded interview segments and the coding dashboard
├── _quarto.yml               <- Website config: pages, navbar, output to docs/
├── index.qmd                 <- Website landing page
├── variables.qmd             <- Column reference generated from the data dictionary
├── deliveries.qmd            <- Delivery register and month-by-month grid from the DATA LOG
├── coding-dashboard/         <- Interview coding dashboard (built by scripts/nlp/coding_dashboard.R)
├── docs/                     <- Rendered website; `quarto publish gh-pages` pushes it to GitHub Pages
├── scripts/
│   ├── 00_ingest-raw.R       <- Sync the Box mirror and validate it against the DATA LOG
│   ├── 00_utils.R            <- Shared helpers (renaming, multi-select encoding, pathways)
│   ├── 01_clean-data.qmd     <- Clean survey + canvassing exports; write processed data + dictionary
│   ├── survey/
│   │   └── 01_chartbook.qmd  <- Preliminary chartbook: counts by state, demographics, what people report
│   └── nlp/                  <- LLM coding of transcripts and the review dashboard
└── .github/                  <- Pull request template
```

## Running the pipeline
```sh
Rscript scripts/00_ingest-raw.R                  # 1. pull new deliveries from Box
quarto render scripts/01_clean-data.qmd          # 2. clean → data/processed/
quarto render scripts/survey/01_chartbook.qmd    # 3. chartbook (reads processed data)
```

Only step 1 needs Box access; rendering works offline from the local mirror. Steps 2 and 3 also accept `quarto render` at the repo root, which builds the whole website (see below). The rendered site in `docs/` is committed with the sources.

> [!IMPORTANT]
> Every step fails loudly on anything unexpected: a delivery missing from the DATA LOG, a column or answer option that doesn't match the dictionaries, a file no naming pattern claims. The fix is always a deliberate update to the mapping that failed, never a relaxed check. The cleaning document lists the warnings that are expected.

## Development

### Scripts and documents
* `00_ingest-raw.R` is the only script that touches Box. It downloads by file ID (top-level deliveries to the mirror, the "Interview Transcripts" subfolder to `data/raw/interview-transcripts/`), records checksums in `data/raw/box-manifest.csv`, and refuses to sync if the Box folder and the team's `* DATA LOG *.xlsx` disagree or a delivery isn't marked PII-skimmed. It also parses the log's Details sheet into `data/raw/deliveries.csv`: one row per file with tool, form, closed/open, complete/partial, test flag, collection window, ID range, and notes. The file name is only a second opinion; the sync warns when it disagrees with the log.
* `01_clean-data.qmd` classifies files from `deliveries.csv` (never from file-name patterns), must account for every file in the mirror (cleaned or set aside with a reason), checks each file's dates and IDs against the log, and writes `survey_clean.csv`, `canvassing_clean.csv`, `canvassing_revised_clean.csv`, and `data-dictionary.csv`. Pages read the CSVs with `read_clean()`, which restores column types from the dictionary (ordered categories, logicals, text IDs and ZIPs), so the dictionary is the one description of the files. Shared helpers live in `00_utils.R` and are sourced by every document.
* `deliveries.qmd` renders the log as a site page: the file register, the team's month-by-month grid, and a cross-check between the two.
* Analysis documents go in `scripts/survey/` (descriptive) or `scripts/nlp/` (text). They read only from `data/processed/`.
* Documents are written for the research lead, not for programmers: each step is explained in plain language before its code, code is folded, and mechanical chunks are hidden.

### Column conventions
* Questions keep the questionnaire's numbering: `q1` (connection to care), `q2x`/`q3x`/`q4x` (challenges / supports / who helps, `x` = pathway letter a–d), `q6` (ideal care). Demographics get plain names (`age`, `hh_income`, `zip`).
* Choose-all-that-apply questions become one logical column per answer (`q2a_unaffordable`, …): `TRUE` chosen, `FALSE` seen but not chosen, `NA` not shown or skipped. Anything not in the answer dictionary lands in `{q}_other` / `{q}_other_text`.
* Single-answer questions are ordered factors. `pathway` (current / past / future / observer / none) is derived from `q1`.
* Answer dictionaries use the wording observed in exports, and may list several accepted wordings for one answer when the form is revised.

### Adding a new delivery or answer option
1. Run the ingest script. If it stops, reconcile with the team (usually the DATA LOG).
2. Render `01_clean-data.qmd`. If it stops on a column or answer it doesn't know, add the wording to `col_map` or the option dictionary — as an alias if it's a rewording of an existing answer.
3. Read the warnings in the rendered document; a new one means a new fact about the instrument. Record it in `SURVEY.md`.
4. Render the chartbook and commit both HTML files.

### GitHub workflow
Each task corresponds to an issue. Work happens on a branch named after the issue (`iss1` for issue 1), and the pull request links the issue to close on merge. Reviewers check that the documents render without new warnings, that values make sense, and that the prose is readable by someone who will not open the code.

### Dependencies
Packages come from the system library; there is no lockfile. Required: tidyverse, readxl, here, cli, boxr, gt, urbnthemes, scales, reactable. The NLP scripts also use ellmer. If reproducibility across machines becomes a need, [`rv`](https://github.com/A2-ai/rv) (a uv-style package manager for R) is the tool to try.

## Access and credentials
* **Box**: run `boxr::box_auth()` once in an R console (browser login; the token caches locally), and add the delivery folder's ID — the number in its Box URL — to `~/.Renviron` as `BOX_RAW_FOLDER_ID=<id>`. You need read access to the delivery folder.
* **Census API key**: the chartbook pulls ACS figures (national benchmarks, adults per state) through `tidycensus` on first render, which needs `CENSUS_API_KEY` in `~/.Renviron` ([get one here](https://api.census.gov/data/key_signup.html)). The pulls are cached in `data/raw/reference/`, so later renders work offline.
* **USDA ERS RUCA codes**: public; downloaded automatically into `data/raw/reference/` the first time the chartbook renders.
* **Care-policy grades**: `data/raw/reference/care_policy_grades_2024.csv` is the one hand-entered reference file — each state's grade from the Century Foundation's *Care Matters: A 2024 Report Card for Policies in the States*, as tabulated in the project's Population Data Memo (Box). It is gitignored with the rest of `data/`; re-create it from the memo's state table if missing.
* **LLM coding** (`scripts/nlp/`): credentials for the model endpoint used by `ellmer`; see the notes in `scripts/nlp/PLAN-llm-coding.md`.

## Website
The rendered documents form a Quarto website (`_quarto.yml`): `quarto render` at the repo root builds every page into `docs/`. Pages re-execute only when their source changes (`freeze: auto`). The interview coding dashboard is built separately with `Rscript scripts/nlp/coding_dashboard.R` into `coding-dashboard/`, which the site copies in as a resource.

To publish, run `quarto publish gh-pages --no-render` from the repo root: it pushes `docs/` to the `gh-pages` branch, which GitHub Pages serves at <https://ui-research.github.io/one-million-care-conversations/>. Publishing is a deliberate step, not tied to merging — publish from a branch to share a preview, and again after merge.
