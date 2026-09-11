# Plan: LLM-assisted coding pipeline + validation

Status: **plan only, nothing built yet** (written 2026-09-11). Revisit in a fresh
session with the kickoff prompt at the bottom.

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

## Kickoff prompt for the next session

Paste this into a new Claude Code session in this repo:

```
Read scripts/nlp/PLAN-llm-coding.md and CLAUDE.md, then build the validation pipeline
it describes, in Python, under scripts/nlp/:

1. codebook_to_csv.py, segment.py, code_segments.py, validate.py, plus a
   requirements.txt (anthropic[bedrock], pydantic, pandas, scikit-learn, krippendorff).
2. Use AnthropicBedrockMantle from the anthropic SDK; take region and model ID from
   environment variables (AWS_REGION, IMCC_MODEL) with claude-sonnet-5 as the default
   model. Do not hardcode credentials.
3. Use messages.parse with the Pydantic schema in the plan, the system prompt from
   scripts/nlp/coding_prompt.md, prompt caching on the system prompt and transcript,
   adaptive thinking, effort medium. Match the CSV columns written by
   scripts/nlp/ellmer_coding_example.R.
4. Everything written under data/ must stay gitignored; check `git status` before
   finishing. Never print transcript text to the terminal beyond short excerpts.
5. Dry-run mode: a --limit N flag that codes only the first N segments so I can smoke
   test against Bedrock cheaply before the full run.
6. validate.py should work with any number of human_*.csv and llm_*.csv files in
   data/processed/interview-coding/ and write agreement.md there.

Ask me for Bedrock region and model IDs before running anything against the API. Do
not run the full coding job without confirming cost first.
```
