# One Million Conversations About Care

Data analysis code for the Urban Institute's research partnership with [Caring Across Generations](https://caringacross.org/) on the **1M Conversations About Care** initiative: one million families engaged through surveys and guided conversations about care challenges, ideal supports, and what's working for families.

This repo holds only the analysis code. Data and project documents live on Box and are never committed. [SURVEY.md](SURVEY.md) documents the survey instrument as observed in the data (routing, distribution channels, export quirks).

- **Quantitative** — cleaning the coalition's survey and canvassing exports; descriptive analysis by theme, demographic group, and place
- **Qualitative** — thematic analysis of interview transcripts and open-ended answers. Hand-coding covers a sample; LLM-assisted coding, validated against the human-coded sample, scales to the full corpus

## Data notes

- **No PII.** Coalition data shared with Urban must contain no personal identifying information (not IRB-approved; legally non-negotiable). No coalition data belongs in this repository — `.gitignore` blocks `data/`, rendered HTML (which embeds data rows), and project PDFs/DOCX.
- **Not "nationally representative."** Coalition-collected data cannot be described that way in any Urban publication.

## Structure

```
data/
  raw/
    box-manifest.csv        # what was fetched from Box (file IDs, checksums)
    Raw data backups/       # mirror of the Box delivery folder, incl. the data log
    interview-transcripts/  # interview transcripts pulled from Box
    reference/              # public lookups downloaded on first render (USDA ERS RUCA codes by ZIP)
  processed/                # cleaned outputs (only data-dictionary.csv is committed)
    interview-coding/       # LLM-coded interview segments + the coding dashboard
scripts/
  00_ingest-raw.R           # syncs the mirror from Box via the API, validates against the data log
  00_utils.R                # shared helpers (column renaming, multi-select encoding, pathways)
  01_clean-data.qmd         # cleans survey + canvassing exports, writes processed data + dictionary
  survey/
    01_chartbook.qmd        # response counts by state, demographics, what people report
  nlp/
    coding_prompt.md        # codebook-driven prompt for LLM coding of transcripts
    ellmer_coding_example.R # runs the coding pass via ellmer
    coding_dashboard.R      # builds the coded-transcript review dashboard
    PLAN-llm-coding.md      # design notes for the coding pipeline
```

## Running the pipeline

One-time setup for the Box sync: run `boxr::box_auth()` in an R console
(browser login; the token caches locally), and add the delivery folder's ID —
the number in its Box URL — to `~/.Renviron` as `BOX_RAW_FOLDER_ID=<id>`.

```sh
Rscript scripts/00_ingest-raw.R                  # pull new deliveries from Box
quarto render scripts/01_clean-data.qmd          # clean → data/processed/
quarto render scripts/survey/01_chartbook.qmd    # chartbook (reads processed data)
```

Each step fails loudly on anything unexpected — a delivery missing from the
data log, a column or answer option that doesn't match the dictionaries, a
file no naming pattern claims. That is by design: the fix is always a
deliberate update to the mapping that failed, never a relaxed check. Only the
ingest step needs Box access; rendering works offline from the local mirror.

The rendered documents are the deliverables: `01_clean-data.html` documents
the cleaning for review, and `01_chartbook.html` is the preliminary chartbook
for the coalition. Both stay out of git because they embed data.

The interview coding dashboard is built with
`Rscript scripts/nlp/coding_dashboard.R` and published at
<https://ui-research.github.io/one-million-care-conversations/>.

Packages come from the system library (no renv): tidyverse, readxl, here, cli,
boxr, urbnthemes, scales, reactable; the NLP scripts also use ellmer.
