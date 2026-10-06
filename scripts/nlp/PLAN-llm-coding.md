# Plan: LLM-assisted coding pipeline + validation

Status: **built and run** (plan written 2026-09-11; Python coder, v6 codebook, and the
Sonnet 5 / Opus 5.5 benchmark runs on 2026-10-06). See "What exists now" and Findings.

## What exists now (2026-10-06)

- `scripts/nlp/00_ingest-codebook.R`: Bree's `IMCC Codebook v6.xlsx` (in
  `data/raw/codebook/`) to `data/processed/codebook.csv` (167 codes, 10 domains).
- `scripts/nlp/01_open-ended.R`: every open-ended answer from the survey (q5a/q5c/q5d,
  q7), the canvassing forms (Q2 hard, Q3) and the pre-launch poll into
  `data/processed/open_ended.csv` (2,061 answers with text).
- `scripts/nlp/02_code-text.py`: the coder. Official `anthropic` Python SDK on Bedrock,
  prompt caching on the codebook and the transcript, adaptive thinking with a chosen
  effort, one tool call (`submit_codes`) as the structured output, pydantic validation,
  per-call token log, manifest with prompt hashes and a cost estimate. Transcripts are
  one call per participant segment with the transcript as cached context; open-ended
  answers go 20 per call grouped by question. `--limit N` smoke-tests, `--resume`
  finishes an interrupted run from the saved raw responses. Output under
  `data/processed/llm-coding/<run_id>/`.
- `scripts/nlp/03_cost-report.py`: usage logs to `scripts/nlp/COST-REPORT.md` (committed;
  aggregates only).
- `scripts/nlp/04_compare-runs.py`: two runs to an agreement file plus the per-run hand-review
  files (all gitignored, they quote passages).
- `scripts/nlp/coding_dashboard.R`: now reads a run folder; adds the open-ended answers tab
  (code counts by tool, answers with highlighted excerpts); writes into the run folder and
  only copies to the published `coding-dashboard/` on request.
- Prompts: rules in `scripts/nlp/coding_prompt.md` (shared), task framing and user
  templates in `scripts/nlp/prompts/` (see its README).
- `scripts/nlp/ellmer_coding_example.R` is superseded: ellmer 0.4.0 cannot read the
  thinking blocks Opus 5.5 and Fable always return and does not cache. Kept for the
  September findings below.

### Bedrock access as of 2026-10-06 (IAM user in `~/.Renviron`, us-east-1)

| Model | Works | How |
|---|---|---|
| Sonnet 5 | yes | `anthropic.claude-sonnet-5` on the Claude-in-Bedrock endpoint (`AnthropicBedrockMantle`) |
| Opus 5.5 | yes | `global.anthropic.claude-opus-5-5` through the legacy InvokeModel client (`AnthropicBedrock`); the new endpoint returns 403 because the IAM user lacks `aws-marketplace:Subscribe` |
| Opus 5 | yes | `anthropic.claude-opus-5` on the new endpoint |
| Fable 5.1 | **no** | legacy path: `data retention mode 'default' is not available for this model` (account-level Bedrock data-retention setting must be switched to the 30-day mode); new endpoint: 404. Ask Rob. |

Two Bedrock limitations shaped the code: structured outputs (`output_config.format`)
and `strict` tools are not available there, so the schema is a plain tool definition
validated client-side; forced `tool_choice` is rejected on Opus 5.5 and Fable 5.1, so
the prompt asks for the tool call and the code falls back to "no tool call" as an
error.

## Where we are

- A feasibility pilot exists: 3 interview transcripts coded by Claude (Fable) inside a
  Claude Code session, 94 coded segments in `data/processed/interview-coding/coded_segments.csv`,
  decisions and codebook gaps in `CODING-NOTES.md` there. Rendered as the dashboard
  (`coding_dashboard.R`, live on GitHub Pages). Team reaction was positive.
- The pilot is **unvalidated**: single pass, no human coding to compare against, no
  agreement stats, and not reproducible (interactive session, not a script).
- Codebook: `IMCC Codebook v3.docx` (Bree). Known issues: `CHILD_CARE` and
  `DISABILITY_CARE` defined in two domains, stray spaces/underscores in code names,
  Solutions rows without definitions, no multi-label policy, no
  Challenges/Desired/Solutions boundary rule. Gaps found in practice are listed in
  `CODING-NOTES.md` (peer support, institutional harm, eligibility gap, provider voice,
  bilingual policy).

## Decisions taken

- **Python**, official `anthropic` SDK. Validation and agreement stats are easier in
  Python (`scikit-learn`, `krippendorff`), and the eventual 1M-conversation run will be
  Python anyway.
- **Amazon Bedrock** as the endpoint so transcript text stays inside Urban's AWS
  account (Rob's data-governance concern). Client: `AnthropicBedrockMantle(aws_region=...)`
  from the SDK; model IDs carry the `anthropic.` prefix. Bedrock has **no Message
  Batches API** (the half-price async endpoint), which matters at 1M scale but not for
  validation. Confirm which Claude models are enabled in Urban's Bedrock console.
- **Sonnet 5 first**, then the same run on a Fable/Opus-tier model. The pilot was done
  with Fable, so this gives a Sonnet-vs-Fable comparison at no extra design cost.
  Model quality is an empirical question here, not a prior.
- **Unit of analysis = speaker turn** (participant speech only; interviewer and
  facilitator turns excluded). Same as the pilot. Needs team ratification.
- **Multi-label** allowed; a segment may carry codes from several domains.

## Pipeline design

```
transcripts (docx, Box)            codebook (docx, Bree)
        │                                  │
   segment.py  ──►  segments.csv      codebook_to_csv.py ──► codebook.csv
        │                                  │
        └──────────────┬───────────────────┘
                       ▼
                  code_segments.py  ──►  llm_<model>.csv      (one row per segment × code)
                       │
   human_<coder>.csv ──┤
                       ▼
                  validate.py  ──►  agreement.md + confusion tables
```

All of `data/` stays gitignored. Only the scripts and this plan are committed.

### 1. `codebook_to_csv.py`

pandoc the docx to GFM (the dashboard script already does this in R; port the same
parse), normalise code names (`CARE_ PRIMARY_PROVIDER` → `CARE_PRIMARY_PROVIDER`), and
disambiguate the two duplicates by domain prefix (`DESIRED_DISABILITY_CARE`,
`DESIRED_CHILD_CARE`) until Bree renames them in v4. Output columns:
`domain, parent, code, definition, include, exclude, keywords, question`.

### 2. `segment.py`

pandoc each transcript to plain text, split on speaker labels, keep participant turns,
drop interviewer/facilitator turns, assign stable `segment_id = <stem>_<nnn>`, keep the
timecode if present. Output `segments.csv`: `segment_id, file, speaker, timecode, text`.
Both humans and the model code **the same segment table**, so agreement is computed on
identical units. This is the single most important design choice for validation.

Bilingual group transcript: keep the Spanish original and the in-room translation in
the same segment; the prompt tells the model to code from the original.

### 3. `code_segments.py`

One API call per segment. The whole transcript goes in as context so the model can
resolve references, with the codebook and transcript in the cached prefix:

```
system  = CODING_PROMPT (below) + codebook.csv rendered as a table       ← cache_control
user    = [ full transcript text ]                                        ← cache_control
        + "Code segment <segment_id>: <text>"
```

Structured output via `client.messages.parse(..., output_format=CodedSegment)`:

```python
class CodeAssignment(BaseModel):
    code: str                 # must be a code in codebook.csv, or "<DOMAIN>_OTHER"
    excerpt: str              # verbatim span from the segment that supports the code
    rationale: str            # one sentence
    confidence: Literal["high", "medium", "low"]

class CodedSegment(BaseModel):
    segment_id: str
    codes: list[CodeAssignment]        # empty list = no code applies
    possible_new_code: str | None      # free text when an _OTHER code was used
```

Post-validate `code` against the codebook in Python (structured output guarantees
shape, not vocabulary). Reject and retry once on an unknown code; log if it persists.

Run settings: adaptive thinking (the default), `output_config={"effort": "medium"}` to
start, `max_tokens=4000`. Sweep effort only if agreement is disappointing. Run segments
concurrently (a `ThreadPoolExecutor` with 4–8 workers is enough; Bedrock throttles
per-model, so catch `RateLimitError` and back off).

Output `llm_<model>.csv` with the same columns as the pilot CSV plus `segment_id`,
`model`, `effort`, `run_date`. Save the raw JSON responses too (`raw/<segment_id>.json`)
so nothing needs re-running to inspect a decision.

### 4. Human coding (Bree + ideally one more coder)

Give the coders `segments.csv` as a spreadsheet with one row per segment and a
free-text `codes` column (semicolon-separated code names), or a long sheet with one row
per segment × code. Blind to the model output. Two humans lets us report
**human–human agreement as the ceiling** the model is judged against; one human means
we can only report model-vs-Bree.

### 5. `validate.py`

Inputs: `segments.csv`, `human_<coder>.csv` (one or two), `llm_<model>.csv` (one or
more). Everything becomes a segment × code boolean matrix.

Report, for each pair of coders (human–human, human–Sonnet, human–Fable, Sonnet–Fable):

| Level | Metric | Why |
|---|---|---|
| Segment, set-valued | Krippendorff's α with MASI distance (`krippendorff` pkg or NLTK's `masi_distance`) | one headline number for multi-label agreement |
| Per code | precision / recall / F1 of the model against the human, plus Cohen's κ | tells you *which* codes the model over- or under-applies |
| Per domain | same, pooled | 94 segments is thin; most codes have n < 5, so per-code numbers will be noisy. Domain-level is the honest summary |
| Confusion | pairs of sibling codes most often swapped | feeds codebook revisions (the boundary rules) |

Also report: agreement broken down by the model's `confidence` field (if `low` really
predicts disagreement, that's the human-review triage signal), and the list of
`_OTHER` uses with `possible_new_code` text (candidate new codes for Bree).

Write `agreement.md` with the tables and a short interpretation. Never commit it (it
quotes excerpts).

### 5b. Cost design (decided 2026-09-11 after the ellmer runs)

The per-turn design above re-sends the transcript on every call; without caching that
made 3 transcripts cost ~$5. For production: (a) prompt caching on codebook +
transcript, always; (b) for long transcripts, **one call per transcript** returning
all segments in one structured list (~20K in, few K out: cents on Sonnet, <$0.50 on
Opus); (c) short canvassing/survey responses are one call each with the codebook
cached, or several packed per call. Rough list-price scale for 1M short responses:
Sonnet ~$3K, Opus ~$8K, Fable ~$12K; long transcripts are a rounding error. Keep the
per-turn mode only as a validation option. Manu's personal AWS account is for
piloting; production runs on Urban's account.

### 6. Cost (validation stage only)

Three transcripts, roughly 100 participant segments, transcript context ~10–30K tokens
each but cached after the first call. Well under $5 per model run at list prices. Not a
consideration until the 1M scale-up, where the design changes anyway (short survey
responses, no transcript context, Batches API if the endpoint allows it).

## Open questions to settle with the team

1. **Rob:** is Bedrock in Urban's account approved for these transcripts? Which models
   are enabled? Is prompt caching on Bedrock acceptable (cached prefixes are retained
   server-side for minutes)?
2. **Bree/Teresa:** ratify the unit of analysis (speaker turn), multi-label policy,
   exclusion of interviewer speech, and the Challenges/Desired/Solutions boundary rule
   from `CODING-NOTES.md`. Ideally these go into the codebook v4 preamble.
3. **Bree:** will she code the same three transcripts at segment level, and is a second
   coder available?
4. **Bilingual policy:** code from the Spanish original or the translation?
5. **Codebook v4 timing:** duplicate code names and missing Solutions definitions should
   be fixed before the validation run, otherwise the model is being scored against an
   ambiguous target.

## Coding prompt

The system prompt lives in `scripts/nlp/coding_prompt.md` so the R test script and the
Python pipeline share it verbatim. The codebook table is appended after it at runtime,
rendered as Markdown from `codebook.csv`. Keep prompt and codebook in the cached
prefix; put the segment last.

## R test version (ellmer)

`scripts/nlp/ellmer_coding_example.R` is a self-contained smoke test of the same
design: pandoc the codebook and transcripts, split participant turns, one structured
call per segment via `chat_aws_bedrock()` + `parallel_chat_structured()`, write
`llm_ellmer_<model>.csv`.

Verified 2026-09-11 (ellmer 0.4.0, default AWS profile, us-east-1,
`us.anthropic.claude-sonnet-5`): Bedrock connection works, the codebook and segment
parsing work (123 codebook rows, 122 participant segments), and the structured schema
returns sensible codes on a synthetic segment. **Not yet run on real transcript
segments** pending Rob's sign-off on Bedrock for this data. Two limitations of the R
path that the Python version does not share: thinking has to be disabled (ellmer's
Bedrock provider errors on reasoning blocks) and there is no prompt caching, so the
transcript context is billed on every call. The Python version should produce the same
CSV columns so `validate.py` can read both.

## Findings from the first Sonnet 5 run (2026-09-11, ellmer path, all 122 segments)

241 assignments, reviewed by hand against the codebook. Roughly 80% right, 10%
defensible, 10% wrong. Versus the pilot: recall 72%, precision 42%, mean Jaccard 0.39
on the 39 segments both coded. Letter and the institutional-harm sequence were coded
better than the pilot; Spanish handled correctly; `low` confidence flagged 19 of the 21
rows I would also question. Systematic problems, all fixable in the prompt or
segmentation before the validation run:

1. **Role codes re-applied every turn.** CAREGIVER_FAMILY 17× in one interview,
   CHRONIC_CONDITION_CARE / CHILD_CARE likewise. Rule to add: Participant
   Characteristics codes are assigned once per participant, on the turn that
   establishes them, not on every turn that is consistent with them.
2. **Cross-turn context imported** ("as established earlier"); one excerpt quoted from
   the adjacent segment. Rule to add: every excerpt and rationale must be supportable
   from the segment text alone.
3. **Current vs former caregiving.** The widow was never coded FORMER_CAREGIVER. Rule to
   add: use tense and the transcript frame; a caregiver whose care recipient has died
   is FORMER_CAREGIVER.
4. **_POTENTIAL_QUOTE overuse** (31 vs pilot 12), incl. fragments and another person's
   reported speech. Rule to add: at most one per segment, self-contained sentence, the
   participant's own words.
5. **Translator turns coded as participant speech** (5 rows). Segmentation: drop
   `Translator` turns, or merge into the preceding Spanish turn.
6. Individual misfires to use as prompt examples: IMPROVED_WELLBEING for the
   caregiver's own health; CARE_MULTIPLE_SETTINGS for multiple populations; ACCESS_BARRIER
   for a clinician ending a call; LOSS_OF_CONTROL for "my goal was for him to stay home."

Cost of the run: ~2.4M input tokens (no caching on the ellmer path), about $5.

**Rerun with fixes 1–5 applied to `coding_prompt.md` and Translator turns dropped
(same day):** 171 assignments on 117 segments (was 241/122). CAREGIVER_FAMILY in the
long interview 17 → 3, FORMER_CAREGIVER now used (0 → 5), zero cross-turn rationales,
potential quotes 31 → 13, no IMPROVED_WELLBEING / CARE_MULTIPLE_SETTINGS misfires.
Against the pilot: precision 42% → 53%, Jaccard 0.39 → 0.46, recall unchanged at 71%.
Remaining gaps are mostly genuine boundary disagreements to settle in the codebook.

**Model access on Bedrock (us-east-1, default profile):** Sonnet 5, Opus 5, and
Opus 4.8 respond. Fable 5.1 is listed but returns "data retention mode 'default' is
not available for this model" — it needs the account's Bedrock data-retention setting
changed to the 30-day mode first (an AWS-side config; ask Rob). Fable also cannot run
thinking-disabled, so it needs the Python path, not ellmer.

## Findings from the v6 benchmark runs (2026-10-06)

Both runs: codebook v6, adaptive thinking, effort medium, 263 transcript segments and
2,058 answer passages (1,998 distinct answers; 60 were in the input twice, see the
dedupe now in `01_open-ended.R`). Cost figures are in `COST-REPORT.md`.

| | Sonnet 5 | Opus 5.5 |
|---|---:|---:|
| Transcript assignments (segments with a code) | 351 (200 of 263) | pending |
| Answer assignments (answers with a code) | 5,191 (1,918 of 1,998) | pending |
| Codes per coded answer | 2.7 | pending |
| Excerpt verbatim in passage (transcripts / answers) | 98% / 91% | pending |
| Codes outside the codebook | 3 rows (`SUPPORT_FORMAL_SUPPORT`) | pending |
| `_POTENTIAL_QUOTE` (transcripts / answers) | 24 / 155 | pending |
| `_OTHER` with a proposed code (transcripts / answers) | 3 / 61 | pending |
| Cost at list prices | $12.04 | ~$11 for 263 segments + 780 answers so far |

Opus 5.5 was still running when this was written (about one 20-answer call every two
minutes on the `global.` profile, with retries; the transcript phase took 12 minutes).
Finish it with `python scripts/nlp/02_code-text.py --model global.anthropic.claude-opus-5-5 --resume`
if it was interrupted, then rerun `03_cost-report.py`, `04_compare-runs.py` and the
dashboard.

**Hand review of the Sonnet 5 run** (all 351 transcript assignments read; a structured
sample of 144 answers covering every 25th answer plus all-sampled `_OTHER`, low
confidence, quote and Participant Characteristics rows). Roughly 75-80% right, 10-15%
defensible, under 10% wrong, on both tasks. What worked: no cross-turn rationales;
`CHALLENGE_LOSS_OF_CONTROL` only with explicit no-choice statements (5 uses, all
right); current vs former caregiving right in every case checked (the widow is
`FORMER_CAREGIVER` once, at the death, never `CAREGIVER_FAMILY`); Spanish coded from the
original; the letter got 17 well-grounded codes; `low` confidence flagged most of the
rows I doubted. What did not:

1. **`CARE_RELATIONSHIP` is over-applied.** 20 transcript uses and 323 answer uses. It
   fires on every mention of "my husband", on relationships that are not
   caregiver-recipient (a daughter's house, "paid caregiver"), and repeatedly for the
   same participant despite the once-per-participant rule. Either Bree narrows the
   definition or the rule needs an example of what does not count.
2. **Participant Characteristics on survey answers** (648 assignments): applied by the
   rules, but the respondent's pathway, relationship and care type are already
   structured survey items. Decide with Bree whether these codes belong on answers at
   all; dropping them removes a third of the answer assignments and most of the
   repetition.
3. **`CHALLENGE_QUALITY_CONCERNS` (30 transcript uses) stretches to opinions** about the
   care industry ("this is a natural progression for 95% of people with dementia").
4. **Outcomes stretches**: `OUTCOME_INDEPENDENCE` for "I choose who I work with",
   `OUTCOME_ECONOMIC_SECURITY` for "work part-time", `OUTCOME_FAMILY_STABILITY` for a
   grandchild's affection. Rule 10 needs an example.
5. **Quotes with reported speech**: two transcript `_POTENTIAL_QUOTE`s are the husband's
   words ("Do you see the tunnel?"), which rule 13 excludes.
6. **Peer support groups have no v6 code.** The model splits them between
   `SUPPORT_FRIEND_COMMUNITY` and `SUPPORT_OTHER` with `SUPPORT_PEER_GROUP` proposed
   repeatedly; "lack of support" in the canvass answers goes to `CHALLENGE_OTHER` with
   `CHALLENGE_LACK_OF_SUPPORT` proposed. Both are codebook gaps, not prompt problems.
7. **Segmentation**: Descript transcripts carry the facilitator's backchannels ("Mm-hmm",
   "Yeah") inside participant turns; harmless under rule 15 but visible in excerpts.

Two malformed replies (the `passages` array sent as a JSON string) and one empty reply
out of 372 calls; the coder repairs the first and retries the second.

## Prompt changes for v6 (2026-10-06)

The rules were generalised from "segment" to "passage" so one rule file serves both
transcripts and short answers; code names were updated to v6 (`CHALLENGE_LOSS_OF_CONTROL`,
`CHALLENGE_ACCESS_BARRIER`, `CHALLENGE_SOCIAL_ISOLATION`, `OUTCOME_*`, `NEED_OTHER`);
`CARE_RELATIONSHIP` joined the once-per-participant rule; rationales capped at 20
words; a boundary line for the new Ideal System domain. The duplicate code names of v3
are resolved in v6, so the `DESIRED_*` workaround is gone.
