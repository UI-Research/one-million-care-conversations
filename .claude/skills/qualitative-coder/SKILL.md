---
name: qualitative-coder
description: Run, review, and cost the LLM coding of 1MCC interview transcripts and open-ended survey answers against Bree's codebook (Python coder on Bedrock, v6 codebook, dashboard). Use for any coding run, prompt change, hand review, or cost question.
---

# Qualitative coder (1MCC)

Thin workflow skill. The coding rules live in ONE place, `scripts/nlp/coding_prompt.md`;
task framings and user-message templates live in `scripts/nlp/prompts/`. Never restate
or paraphrase the rules here or in a session; read the files. The design, decisions and
findings live in `scripts/nlp/PLAN-llm-coding.md`; read it first.

## Files

| Path | What | Committed? |
|---|---|---|
| `data/raw/codebook/IMCC Codebook v<N>.xlsx` | Bree's codebook, source of truth | no |
| `data/processed/codebook.csv` | flat parse of the newest codebook (`00_ingest-codebook.R`), with `version` | no |
| `data/raw/interview-transcripts/*.docx` | transcripts, `nopii_` prefixed | no |
| `data/processed/open_ended.csv` | every open-ended answer (`01_open-ended.R`) | no |
| `data/processed/llm-coding/segments.csv` | transcript unit table, one row per participant segment | no |
| `data/processed/llm-coding/<run_id>/` | one run: `manifest.json`, `usage.csv`, `coded_transcripts.csv`, `coded_open_ended.csv`, `raw/*.json`, rendered system prompts | no |
| `data/processed/interview-coding/` | the September pilot (v3 codebook) and its notes | no |
| `scripts/nlp/02_code-text.py` | the coder (Python, `anthropic[bedrock]`) | yes |
| `scripts/nlp/03_cost-report.py` → `scripts/nlp/COST-REPORT.md` | cost benchmark from the usage logs | yes |
| `scripts/nlp/04_compare-runs.py` | two runs → `compare_<a>_vs_<b>.md` + per-run `review_*.md` (the hand-review files) | yes |
| `scripts/nlp/coding_prompt.md`, `scripts/nlp/prompts/` | prompts | yes |
| `scripts/nlp/coding_dashboard.R` | dashboard builder | yes |
| `scripts/nlp/PLAN-llm-coding.md` | design, decisions, findings, Bedrock access matrix | yes |

Nothing under `data/` is ever committed. Print transcript or answer text only as short
excerpts.

## Coded CSV contract

Every coder (pilot, model run, human) produces the same columns so the dashboard and
comparisons work unchanged. Transcripts:
`segment_id, file, speaker, code, excerpt, rationale, confidence, domain, parent_code`
plus `in_codebook, possible_new_code, model, effort, run_date`. Open-ended answers:
`answer_id, tool, question` in place of `segment_id, file, speaker`; an answer with no
code keeps one row with `code` empty so coverage can be counted. `excerpt` must be
verbatim from the passage so the dashboard can highlight it.

## Standing decisions (ratification by Teresa/Bree pending)

- Unit = participant speaker turn for transcripts; the letter is one segment;
  interviewer, facilitator, translator turns and facilitator questions are excluded.
  Unit = one answer for the open-ended questions.
- Multi-label allowed. Participant Characteristics codes and CARE_RELATIONSHIP once per
  participant, on the passage that states the fact.
- Code Spanish from the original; quote the Spanish.
- Effort `medium`, adaptive thinking, 20 answers per call, 4 workers, for every
  benchmarked model, so runs are comparable.

## Commands

```sh
Rscript scripts/nlp/00_ingest-codebook.R                     # newest codebook xlsx -> codebook.csv
Rscript scripts/nlp/01_open-ended.R                          # survey/canvass/poll answers -> open_ended.csv
export AWS_REGION=us-east-1                                  # credentials via the AWS chain (~/.Renviron has the keys)
python scripts/nlp/02_code-text.py --model anthropic.claude-sonnet-5 --limit 5          # smoke test, cents
python scripts/nlp/02_code-text.py --model anthropic.claude-sonnet-5                    # full run
python scripts/nlp/02_code-text.py --model global.anthropic.claude-opus-5-5             # Opus 5.5 (legacy endpoint)
python scripts/nlp/02_code-text.py --model anthropic.claude-sonnet-5 --resume           # finish an interrupted run
python scripts/nlp/03_cost-report.py                          # rebuild COST-REPORT.md
python scripts/nlp/04_compare-runs.py <run_a> <run_b>          # agreement tables + review files (gitignored)
Rscript scripts/nlp/coding_dashboard.R                        # dashboard
```

Full-run cost at list prices (2026-10-06, 263 segments + 2,061 answers): Sonnet 5 about
$9, Opus 5.5 about $15, Fable 5.1 projected about $35. Do not launch a full run or a
bigger model without saying the cost and getting a yes. Fable 5.1 is blocked on an AWS
account setting (see the PLAN). Never redeploy the GitHub Pages site (`gh-pages`
branch) with a new run unless Manu explicitly asks.

## Reviewing a model run (do this by hand, every run)

`04_compare-runs.py` writes the review file (`<run>/review_<task>.md`): for each coded
passage, the passage text, then each assignment with its codebook definition, exclude
rule, excerpt, and rationale. Read all of it.
Judge each assignment right / defensible / wrong and report the tally plus the
patterns. Check specifically:

1. Role codes (Care Role, Care Type, Location, CARE_RELATIONSHIP) re-applied on every
   turn instead of once.
2. Rationales that lean on other turns ("as established earlier"); excerpts not in the
   passage.
3. Current vs former caregiving where the care recipient has died.
4. `_POTENTIAL_QUOTE` count and whether each is a self-contained, quotable sentence in
   the participant's own words.
5. Stretches: CHALLENGE_LOSS_OF_CONTROL without an explicit no-choice statement,
   CHALLENGE_ACCESS_BARRIER for a person being unhelpful, CHALLENGE_SOCIAL_ISOLATION for
   a missing service, Outcomes codes for things unrelated to care being met,
   CARE_MULTIPLE_SETTINGS for multiple populations.
6. Spanish passages: coded from the original, Spanish in the excerpt.
7. Codes outside the codebook (`in_codebook == FALSE`); `_OTHER` uses and their
   `possible_new_code`.
8. Whether the `low` confidence flag tracks the assignments you doubt.
9. Open-ended answers: share of answers left uncoded per question, and whether the
   Framing and Ideal System codes are applied to q7 ("what could become possible").

Then compare runs or compare to human coding: align rows to passages by id, report
recall / precision / per-passage Jaccard and a domain-level table, list zero-overlap
passages with both code sets. Numbers go in a table in the reply; the interpretation is
what matters.

## Changing the prompt

Edit `scripts/nlp/coding_prompt.md` (rules) or `scripts/nlp/prompts/task_*.md`
(framing) only. Add a rule as a concrete instruction with the failure it prevents;
prefer an example over an adjective. Rerun, redo the review and the comparison, and
record before/after numbers in `PLAN-llm-coding.md` under Findings. Do not tune the
prompt toward the pilot or toward one model: the pilot is one unvalidated coder, not
ground truth. Bree's coding is the reference once it exists.

## Codebook feedback for Bree

Keep a running list in `data/processed/interview-coding/CODING-NOTES.md`: gaps found
in practice, boundary rules that resolved disagreements, duplicate or undefined codes,
and every `possible_new_code` the model proposed with an example excerpt. Flat, one
item per bullet, in her vocabulary (domain, parent, code).
