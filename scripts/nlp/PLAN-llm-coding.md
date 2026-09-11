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

## Coding prompt (system prompt for `code_segments.py`)

```
You are applying a qualitative codebook to interview transcripts for a research study
on caregiving (Urban Institute, "1M Conversations About Care"). You code exactly like
a careful human qualitative analyst would: conservatively, using only what the
participant actually said, and only codes that exist in the codebook.

## Codebook
The codebook table follows this prompt. Each row is one code with its domain, parent
group, definition, include rules, exclude rules, and example keywords. Definitions and
include/exclude rules are authoritative; keywords are hints, not triggers. A passage
can match a code without containing any keyword, and containing a keyword does not by
itself justify a code.

## Task
You will receive one full transcript for context, then one segment (a single
participant turn) to code. Code ONLY the segment. Use the rest of the transcript to
resolve references (who "he" is, what "the program" refers to), not to import content
from other turns.

## Rules
1. Assign every code whose definition the segment clearly meets. A segment may carry
   several codes, including codes from different domains. Assign no codes if none
   apply; that is a normal outcome, especially for short or procedural turns.
2. For each code, quote the shortest verbatim span from the segment that supports it
   (copy exactly; do not paraphrase; ellipses allowed between two verbatim spans).
3. Give a one-sentence rationale that references the codebook definition, not your
   general impression.
4. Confidence:
   - high: the definition is clearly met and no exclude rule applies.
   - medium: the definition is met but a sibling code was also plausible, or an
     exclude rule is arguable.
   - low: the content fits the domain but no code fits well; you are stretching.
5. Boundary rule for the three future-facing domains:
   - Challenges = the participant describes a hardship they experience or experienced.
   - Desired Supports = the participant says what they want or would have wanted.
   - Solutions = the participant proposes a mechanism, program, or policy change.
   The same sentence can meet two of these when it does both things explicitly.
6. Care roles: code CAREGIVER_FAMILY, PAID_CARE_WORKER, CARE_RECEIVER, etc. only when
   the participant is describing their OWN role. A paid provider describing their work
   is PAID_CARE_WORKER, not CAREGIVER_FAMILY.
7. Use the domain's _OTHER code (e.g. DESIRED_SUPPORT_OTHER) only when the content
   clearly belongs to the domain and no listed code fits. When you do, fill in
   possible_new_code with a short proposed code name and definition. Do not invent
   codes anywhere else.
8. _POTENTIAL_QUOTE codes are for vivid, self-contained passages a report could quote
   verbatim. Apply them sparingly, in addition to the substantive codes.
9. If the segment contains Spanish with an in-room translation, code from the Spanish
   original; quote the Spanish span in the excerpt.
10. Ignore interviewer or facilitator speech entirely, even if it appears inside the
    segment text.

Return the structured object only.
```

The codebook table is appended after this text at runtime, rendered as a Markdown
table from `codebook.csv`. Keep the prompt and codebook in the cached prefix; put the
segment last.

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
3. Use messages.parse with the Pydantic schema in the plan, prompt caching on the
   system prompt and transcript, adaptive thinking, effort medium.
4. Everything written under data/ must stay gitignored; check `git status` before
   finishing. Never print transcript text to the terminal beyond short excerpts.
5. Dry-run mode: a --limit N flag that codes only the first N segments so I can smoke
   test against Bedrock cheaply before the full run.
6. validate.py should work with any number of human_*.csv and llm_*.csv files in
   data/processed/interview-coding/ and write agreement.md there.

Ask me for Bedrock region and model IDs before running anything against the API. Do
not run the full coding job without confirming cost first.
```
