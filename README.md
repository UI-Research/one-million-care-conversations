# One Million Conversations About Care

Data analysis code for the Urban Institute's research partnership with [Caring Across Generations](https://caringacross.org/) on the **1M Conversations About Care** initiative: one million families engaged through surveys and guided conversations about care challenges, ideal supports, and what's working for families.

This repo holds only the analysis code — data cleaning and the quantitative and qualitative pipelines. Written deliverables and project documents, including the scope of work, live on Box. [SURVEY.md](SURVEY.md) documents the survey instrument as observed in the data (routing, form versions, export quirks).

- **Quantitative** — sampling targets from public microdata (CPS, ATUS, NHIS); descriptive analysis of the coalition's survey data by theme and demographic group
- **Qualitative** — thematic analysis of conversation text. Hand-coding covers a sample; LLM-assisted coding, validated against the human-coded sample, scales to the full corpus

## Data notes

- **No PII.** Coalition data shared with Urban must contain no personal identifying information (not IRB-approved; legally non-negotiable). No coalition data belongs in this repository.
- **Not "nationally representative."** Coalition-collected data cannot be described that way in any Urban publication.

## Structure

```
data/
  raw/
    Raw data backups/   # mirror of the Box delivery folder, incl. data log — never committed
  processed/            # cleaned outputs — never committed (except the data dictionary)
scripts/
  01_clean-data.qmd     # cleans survey + canvassing exports, writes processed data
  02_explore-data.qmd   # summary stats and visualizations
  survey/               # survey descriptive analysis
  nlp/                  # conversation text: coding, validation, scaling
```
