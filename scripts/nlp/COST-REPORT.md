# Cost benchmark: LLM coding of 1MCC text on Amazon Bedrock

Generated 2026-10-06 by `scripts/nlp/03_cost-report.py` from the usage logs of `scripts/nlp/02_code-text.py`. Prices are list prices from https://platform.claude.com/docs/en/about-claude/pricing (2026-10-06); Bedrock bills the same list rates on global endpoints and 10% more on regional (`us.`) inference profiles. Dollar figures are computed from the token counts the API returned, not read from the AWS bill. Reconcile against AWS Cost Explorer for the run dates before quoting them externally.

## What was coded

- 263 participant segments from 5 interview transcripts (one call per segment, with the full transcript as cached context).
- 1998 open-ended answers (survey q5/q7, canvassing Q2/Q3, pre-launch poll), 20 answers per call, grouped by question.
- Codebook v6 (167 codes) rendered as a Markdown table in the system prompt and cached; adaptive thinking; effort as listed; one tool call per request as the structured output.

## Runs

| Run | Model | Endpoint | Effort | Calls | Uncached input | Cache writes | Cache reads | Output (of which thinking) | Cost | Wall-clock (4 workers) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| `20261006_claude-opus-5-5_medium` (in progress) | claude-opus-5-5 | see manifest when finished | medium | 303 | 107.7K | 77.9K | 8.05M | 456.6K (159.2K) | $11.56 | 45 min |
| `20261006_claude-sonnet-5_medium` | anthropic.claude-sonnet-5 | bedrock-mantle | medium | 372 | 247.4K | 47.0K | 9.43M | 954.2K (428.9K) | $12.04 | 35 min |

## Per-unit cost by task

| Run | Task | Units | Calls | Cost | Cost per unit | Output tokens per unit (thinking) | Cached tokens read per call | Wall-clock (4 workers) |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `20261006_claude-opus-5-5_medium (in progress)` | transcript | 263 | 263 | $4.39 | $0.0167 per segment | 477 (188) | 27.7K | 12 min |
| `20261006_claude-opus-5-5_medium (in progress)` | open_ended | 800 | 40 | $7.17 | $0.0090 per answer | 414 (137) | 18.7K | 32 min |
| `20261006_claude-sonnet-5_medium` | transcript | 263 | 263 | $2.73 | $0.0104 per segment | 427 (222) | 27.9K | 6 min |
| `20261006_claude-sonnet-5_medium` | open_ended | 1998 | 109 | $9.31 | $0.0047 per answer | 421 (185) | 19.1K | 29 min |

## Where the money goes

- `20261006_claude-opus-5-5_medium (in progress)`, transcript: uncached input 3%, cache writes 7%, cache reads 33%, output incl. thinking 57%.
- `20261006_claude-opus-5-5_medium (in progress)`, open_ended: uncached input 4%, cache writes 1%, cache reads 2%, output incl. thinking 92%.
- `20261006_claude-sonnet-5_medium`, transcript: uncached input 2%, cache writes 3%, cache reads 54%, output incl. thinking 41%.
- `20261006_claude-sonnet-5_medium`, open_ended: uncached input 5%, cache writes 1%, cache reads 4%, output incl. thinking 90%.

## Projection to the 1M-conversation scale

Open-ended answers are the unit that scales. The per-answer figures below reuse the measured token shape (cached codebook read once per 20-answer call, observed output and thinking tokens per answer) at list prices. Message Batches (50% off) is not available on Bedrock, so no batch discount is applied.

| Model (effort) | Measured cost per answer | Per 1,000 answers | Per 100,000 | Per 1,000,000 |
|---|---:|---:|---:|---:|
| claude-opus-5-5 (medium) | $0.0090 | $9 | $896 | $8,957 |
| anthropic.claude-sonnet-5 (medium) | $0.0047 | $5 | $466 | $4,661 |
| claude-opus-5 (not run; token shape of claude-opus-5-5 at claude-opus-5 prices) | $0.0114 | $11 | $1,143 | $11,431 |
| claude-fable-5-1 (not run; token shape of claude-opus-5-5 at claude-fable-5-1 prices) | $0.0222 | $22 | $2,216 | $22,159 |

## Notes

- Thinking tokens are billed as output tokens; the thinking column is a subset of output.
- A run marked in progress is read from its saved responses; its per-unit figures cover the units coded so far and its total is not a full-run cost.
- The runs coded 2,058 answer passages because 60 answers delivered in two survey exports were in the input twice; the per-answer figures divide by the 1,998 distinct answers, so they carry about 3% of duplicate overhead.
- Cache reads cost 0.1x input on Sonnet 5, 0.05x on Opus 5.5, 0.025x on Fable 5.1; cache writes cost 1.25x. The codebook (about 19K tokens) is written once per task per run and read on every call.
- Wall-clock is the span between the first and last saved response with 4 concurrent requests; the transcript and answer tasks ran one after the other.
- Fable 5.1 could not be run: Bedrock returns `data retention mode 'default' is not available for this model` until the account's Bedrock data-retention setting is changed, and the Mantle endpoint returns 404 for it. Opus 5.5 is reachable only through the legacy InvokeModel path with the `global.` inference profile; the Mantle endpoint returns 403 (`aws-marketplace:Subscribe` not authorized for this IAM user).
- Rows per run and the hand review of coding quality are in `scripts/nlp/PLAN-llm-coding.md` under Findings.
