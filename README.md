# One Million Conversations About Care

## Admin
* [Box folder](https://urbanorg.app.box.com/folder/380112819949?s=yvq09wjknwclk6apl3jdtfvvuc9ua31e) (project documents and data deliveries)
* **Contact**: Manuel Alcalá Kovalski (data science), Teresa Kroeger (research lead)
* **Project code**: 103682-0001-001-00001-1M

## Project overview
Analysis code for the Urban Institute's research partnership with [Caring Across Generations](https://caringacross.org/) on the **1M Conversations About Care** initiative: one million families engaged through surveys, doorstep canvassing, and interviews about care challenges, ideal supports, and what's working. This repository cleans the coalition's data deliveries, produces descriptive summaries, and holds the text-analysis pipeline for interviews and open-ended answers.

[SURVEY.md](SURVEY.md) documents the survey instrument as it actually behaves in the data: routing, distribution channels, export quirks, and known open questions. Read it before touching the cleaning code.

> [!IMPORTANT]
> **No personal information and no respondent data in this repository.** Coalition data shared with Urban must contain no PII (not IRB-approved; legally non-negotiable), and only the generated `data-dictionary.csv` is committed under `data/`. Rendered HTML documents are committed because they show aggregates only.
>
> **Never describe coalition-collected data as "nationally representative"** in any Urban output.

## Repo structure
```
├── README.md
├── SURVEY.md                 <- The survey instrument as observed in the data
├── data/
│   ├── raw/
│   │   ├── box-manifest.csv        <- What was fetched from Box (file IDs, checksums)
│   │   ├── Raw data backups/       <- Mirror of the Box delivery folder, incl. the DATA LOG
│   │   ├── interview-transcripts/  <- Interview transcripts pulled from Box
│   │   └── reference/              <- Public lookups downloaded on first render (USDA ERS RUCA codes)
│   └── processed/                  <- Cleaned outputs; only data-dictionary.csv is committed
│       └── interview-coding/       <- LLM-coded interview segments and the coding dashboard
├── _quarto.yml               <- Website config: pages, navbar, output to docs/
├── index.qmd                 <- Website landing page
├── variables.qmd             <- Column reference generated from the data dictionary
├── coding-dashboard/         <- Interview coding dashboard (built by scripts/nlp/coding_dashboard.R)
├── docs/                     <- Rendered website, served by GitHub Pages
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
* `00_ingest-raw.R` is the only script that touches Box. It downloads by file ID, records checksums in `data/raw/box-manifest.csv`, and refuses to sync if the Box folder and the team's `* DATA LOG *.xlsx` disagree or a delivery isn't marked PII-skimmed.
* `01_clean-data.qmd` must claim every file in the mirror (cleaned, set aside, or error), and writes `survey_clean.rds/.csv`, `canvassing_clean.rds/.csv`, and `data-dictionary.csv`. Shared helpers live in `00_utils.R` and are sourced by every document.
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
* **USDA ERS RUCA codes**: public; downloaded automatically into `data/raw/reference/` the first time the chartbook renders.
* **LLM coding** (`scripts/nlp/`): credentials for the model endpoint used by `ellmer`; see the notes in `scripts/nlp/PLAN-llm-coding.md`.

## Website
The rendered documents form a Quarto website (`_quarto.yml`): `quarto render` at the repo root builds every page into `docs/`, which GitHub Pages serves at <https://ui-research.github.io/one-million-care-conversations/>. Pages re-execute only when their source changes (`freeze: auto`). The interview coding dashboard is built separately with `Rscript scripts/nlp/coding_dashboard.R` into `coding-dashboard/`, which the site copies in as a resource.
