# One Million Conversations About Care

Data analysis code for the Urban Institute's research partnership with [Caring Across Generations](https://caringacross.org/) on the **1M Conversations About Care** initiative: one million families engaged through surveys and guided conversations about care challenges, ideal supports, and what's working for families.

This repo holds only the analysis code — data cleaning and the quantitative and qualitative pipelines. Written deliverables and project documents, including the scope of work, live on Box.

- **Quantitative** — sampling targets from public microdata (CPS, ATUS, NHIS); descriptive analysis of the coalition's survey data by theme and demographic group
- **Qualitative** — thematic analysis of conversation text. Hand-coding covers a sample; LLM-assisted coding, validated against the human-coded sample, scales to the full corpus

## Data notes

- **No PII.** Coalition data shared with Urban must contain no personal identifying information (not IRB-approved; legally non-negotiable). No coalition data belongs in this repository.
- **Not "nationally representative."** Coalition-collected data cannot be described that way in any Urban publication.

## Structure

```
data/
  raw/            # data as delivered (survey/, canvassing/) — never committed
  processed/      # cleaned outputs — never committed
scripts/
  survey/         # survey data cleaning + descriptive analysis
  nlp/            # conversation text: coding, validation, scaling
```
