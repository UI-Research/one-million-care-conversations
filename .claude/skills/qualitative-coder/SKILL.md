---
name: qualitative-coder
description: Workflow for LLM-assisted qualitative coding of 1MCC interview transcripts with the IMCC codebook — running a coding pass, reviewing model output against the codebook, comparing runs to the pilot or to human coding, and drafting codebook revision notes. Use when asked to code transcripts, review or validate coded segments, compare coders, or update the coding prompt.
---

# Qualitative coder (1MCC)

Thin workflow skill. The coding rules themselves live in ONE place,
`scripts/nlp/coding_prompt.md`, shared by the ellmer test script and the Python
pipeline. Never restate or paraphrase those rules here or in a session; read the file.
The plan and its findings live in `scripts/nlp/PLAN-llm-coding.md`; read it first.

## Files

| Path | What | Committed? |
|---|---|---|
| `IMCC Codebook v3.docx` (repo root) | Bree's codebook, source of truth | no (`*.docx` ignored) |
| `data/processed/interview-coding/codebook.csv` | flat parse, 123 rows, code names normalised | no |
| `data/raw/interview-transcripts/*.docx` | transcripts, `nopii_` prefixed | no |
| `data/processed/interview-coding/coded_segments.csv` | the pilot (Fable, in-session, 94 rows) | no |
| `data/processed/interview-coding/llm_ellmer_<model>.csv` | API runs, one row per segment × code | no |
| `data/processed/interview-coding/*_dashboard.html` | rendered dashboards | no |
| `scripts/nlp/coding_prompt.md` | system prompt (rules) | yes |
| `scripts/nlp/ellmer_coding_example.R` | Bedrock smoke-test coder (R) | yes |
| `scripts/nlp/coding_dashboard.R` | dashboard builder | yes |
| `scripts/nlp/PLAN-llm-coding.md` | design, decisions, findings | yes |

Nothing under `data/` is ever committed. Print transcript text only as short excerpts.

## Coded-segment CSV contract

Every coder (pilot, model run, human) produces the same columns so the dashboard and
the comparison scripts work unchanged:
`segment_id, file, speaker, code, excerpt, rationale, confidence, domain, parent_code`
(plus `model`, `run_date`, `possible_new_code` for API runs). `file` is the transcript
stem; `excerpt` must be verbatim from the segment so the dashboard can highlight it.

## Standing decisions (ratification by Teresa/Bree pending)

- Unit = participant speaker turn. Interviewer, facilitator, and translator turns are
  excluded. The letter is one segment.
- Multi-label allowed. Participant Characteristics codes once per participant.
- Code Spanish from the original; quote the Spanish.
- Duplicate v3 code names are disambiguated as `DESIRED_DISABILITY_CARE` /
  `DESIRED_CHILD_CARE` until v4 renames them.

## Commands

```sh
Rscript scripts/nlp/ellmer_coding_example.R 5      # smoke test (5 segments) — check cost first
Rscript scripts/nlp/ellmer_coding_example.R 200    # all segments, Sonnet 5 by default
IMCC_MODEL=us.anthropic.claude-opus-5 Rscript scripts/nlp/ellmer_coding_example.R 200
Rscript scripts/nlp/coding_dashboard.R             # pilot dashboard
Rscript scripts/nlp/coding_dashboard.R data/processed/interview-coding/llm_ellmer_<model>.csv
```

Full runs on the ellmer path cost ~$5 (Sonnet) / ~$13 (Opus) because it has no prompt
caching. Do not launch a full run or a bigger model without saying the cost and
getting a yes. Never redeploy the GitHub Pages site (`gh-pages` branch) with a new run
unless Manu explicitly asks; the published pilot is what the team has seen.

## Reviewing a model run (do this by hand, every run)

Build a review file: for each coded segment, the segment text, then each assignment
with its codebook definition, exclude rule, excerpt, and rationale. Read all of it.
Judge each assignment right / defensible / wrong and report the tally plus the
patterns. Check specifically:

1. Role codes (Care Role, Care Type, Location) re-applied on every turn instead of once.
2. Rationales that lean on other turns ("as established earlier"); excerpts not in the
   segment.
3. Current vs former caregiving where the care recipient has died.
4. `_POTENTIAL_QUOTE` count and whether each is a self-contained, quotable sentence in
   the participant's own words.
5. Stretches: LOSS_OF_CONTROL without an explicit no-choice statement, ACCESS_BARRIER
   for a person being unhelpful, SOCIAL_ISOLATION for a missing service, Outcomes codes
   for things unrelated to care being met, CARE_MULTIPLE_SETTINGS for multiple
   populations.
6. Spanish segments: coded from the original, Spanish in the excerpt.
7. Codes outside the codebook; `_OTHER` uses and their `possible_new_code`.
8. Whether the `low` confidence flag tracks the assignments you doubt.

Then compare to the pilot or to human coding: align rows to segments by locating the
excerpt in the segment text, report recall / precision / per-segment Jaccard and a
domain-level table, list zero-overlap segments with both code sets. Numbers go in a
table in the reply; the interpretation is what matters.

## Changing the prompt

Edit `scripts/nlp/coding_prompt.md` only. Add a rule as a concrete instruction with the
failure it prevents; prefer an example over an adjective. Rerun, redo the review and
the comparison, and record before/after numbers in `PLAN-llm-coding.md` under
Findings. Do not tune the prompt toward the pilot: the pilot is one unvalidated coder,
not ground truth. Bree's coding is the reference once it exists.

## Codebook feedback for Bree

Keep a running list in `data/processed/interview-coding/CODING-NOTES.md`: gaps found
in practice, boundary rules that resolved disagreements, duplicate or undefined codes,
and every `possible_new_code` the model proposed with an example excerpt. Flat, one
item per bullet, in her vocabulary (domain, parent, code).
