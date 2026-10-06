"""Turn the usage logs written by 02_code-text.py into scripts/nlp/COST-REPORT.md.

  python scripts/nlp/03_cost-report.py            # all runs under data/processed/llm-coding/
  python scripts/nlp/03_cost-report.py --runs 20261006_claude-sonnet-5_medium ...

The report holds aggregates only (token counts, dollars, latencies), so it is committed.
Prices come from PRICES in 02_code-text.py; the per-million-answer projection reuses
the measured tokens per answer, so it is an extrapolation of the observed shape, not a
quote.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from datetime import date
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / "data" / "processed" / "llm-coding"
OUT = ROOT / "scripts" / "nlp" / "COST-REPORT.md"

spec = importlib.util.spec_from_file_location("coder", ROOT / "scripts" / "nlp" / "02_code-text.py")
coder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coder)
PRICES, PRICE_SOURCE = coder.PRICES, coder.PRICE_SOURCE


def usd(tokens: dict, p: dict) -> float:
    return (tokens["input"] * p["input"] + tokens["cache_write"] * p["cache_write"]
            + tokens["cache_read"] * p["cache_read"] + tokens["output"] * p["output"]) / 1e6


def token_profile(u: pd.DataFrame) -> dict:
    return {"input": u.input_tokens.sum(), "cache_write": u.cache_creation_input_tokens.sum(),
            "cache_read": u.cache_read_input_tokens.sum(), "output": u.output_tokens.sum(),
            "thinking": u.thinking_tokens.fillna(0).sum(), "calls": len(u), "latency": u.latency_s.sum()}


def usage_from_raw(d: Path) -> pd.DataFrame:
    """Rebuild the usage table from the saved responses of a run that has not finished."""
    rows = []
    for f in sorted((d / "raw").glob("*.json")):
        r = json.loads(f.read_text())
        u = r["usage"]
        rows.append({"call_id": f.stem, "task": "transcript" if f.stem.startswith("nopii") else "open_ended",
                     "status": r["stop_reason"], "input_tokens": u["input_tokens"],
                     "cache_creation_input_tokens": u.get("cache_creation_input_tokens") or 0,
                     "cache_read_input_tokens": u.get("cache_read_input_tokens") or 0, "output_tokens": u["output_tokens"],
                     "thinking_tokens": (u.get("output_tokens_details") or {}).get("thinking_tokens"), "latency_s": None})
    return pd.DataFrame(rows)


def load_runs(names: list[str] | None) -> list[dict]:
    runs = []
    for d in sorted(RUNS.iterdir()):
        if not d.is_dir() or not (d / "raw").exists() or (names and d.name not in names):
            continue
        if (d / "manifest.json").exists():
            m = json.loads((d / "manifest.json").read_text())
            if m.get("limit"):                     # smoke tests are not benchmarks
                continue
            u = pd.read_csv(d / "usage.csv")
        else:                                      # still running: read what has been saved so far
            u = usage_from_raw(d)
            if len(u) < 50:
                continue
            model = json.loads(next((d / "raw").glob("*.json")).read_text())["model"]
            m = {"run_id": d.name, "model": model, "effort": d.name.rsplit("_", 1)[-1], "in_progress": True,
                 "endpoint": "see manifest when finished"}
        ok = u[u.status.isin(["tool_use", "end_turn", "max_tokens", "refusal"])].copy()
        mt = sorted(f.stat().st_mtime for f in (d / "raw").glob("*.json"))
        m["wall_clock_min"] = (mt[-1] - mt[0]) / 60 if len(mt) > 1 else None
        for task, pat in [("transcript", "nopii"), ("open_ended", "batch_")]:
            mts = sorted(f.stat().st_mtime for f in (d / "raw").glob(f"{pat}*.json"))
            m[f"wall_clock_min_{task}"] = (mts[-1] - mts[0]) / 60 if len(mts) > 1 else None
        coded = {t: pd.read_csv(d / f"coded_{t}.csv") for t in ["transcripts", "open_ended"]
                 if (d / f"coded_{t}.csv").exists() and (d / f"coded_{t}.csv").stat().st_size > 1}
        runs.append({"manifest": m, "usage": u, "ok": ok, "coded": coded, "dir": d})
    return runs


def fmt_tokens(n: float) -> str:
    return f"{n / 1e6:.2f}M" if n >= 1e6 else f"{n / 1e3:.1f}K"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", nargs="*", default=None)
    args = ap.parse_args()
    runs = load_runs(args.runs)
    if not runs:
        raise SystemExit("no full runs found under data/processed/llm-coding/")

    n_segments = len(pd.read_csv(RUNS / "segments.csv"))
    n_answers = len(pd.read_csv(ROOT / "data" / "processed" / "open_ended.csv").dropna(subset=["text"]))

    lines = [
        "# Cost benchmark: LLM coding of 1MCC text on Amazon Bedrock",
        "",
        f"Generated {date.today().isoformat()} by `scripts/nlp/03_cost-report.py` from the usage logs of "
        f"`scripts/nlp/02_code-text.py`. Prices are list prices from {PRICE_SOURCE}; Bedrock bills the same list "
        "rates on global endpoints and 10% more on regional (`us.`) inference profiles. Dollar figures are computed "
        "from the token counts the API returned, not read from the AWS bill. Reconcile against AWS Cost Explorer "
        "for the run dates before quoting them externally.",
        "",
        "## What was coded",
        "",
        f"- {n_segments} participant segments from 5 interview transcripts (one call per segment, with the full "
        "transcript as cached context).",
        f"- {n_answers} open-ended answers (survey q5/q7, canvassing Q2/Q3, pre-launch poll), 20 answers per call, "
        "grouped by question.",
        "- Codebook v6 (167 codes) rendered as a Markdown table in the system prompt and cached; adaptive thinking; "
        "effort as listed; one tool call per request as the structured output.",
        "",
        "## Runs",
        "",
        "| Run | Model | Endpoint | Effort | Calls | Uncached input | Cache writes | Cache reads | Output (of which thinking) | Cost | Wall-clock (4 workers) |",
        "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    per_unit = []
    for r in runs:
        m, ok = r["manifest"], r["ok"]
        key = coder.price_key(m["model"])
        p = PRICES[key]
        t = token_profile(ok)
        total = usd(t, p)
        tag = " (in progress)" if m.get("in_progress") else ""
        lines.append(f"| `{m['run_id']}`{tag} | {m['model']} | {m['endpoint']} | {m['effort']} | {t['calls']} | {fmt_tokens(t['input'])} | "
                     f"{fmt_tokens(t['cache_write'])} | {fmt_tokens(t['cache_read'])} | {fmt_tokens(t['output'])} ({fmt_tokens(t['thinking'])}) | "
                     f"${total:.2f} | {m['wall_clock_min']:.0f} min |")
        for task, n_units, label in [("transcript", n_segments, "per segment"), ("open_ended", n_answers, "per answer")]:
            g = ok[ok.task == task]
            if g.empty:
                continue
            if m.get("in_progress"):               # units actually coded so far: 1 segment per call, 20 answers per batch
                n_units = len(g) if task == "transcript" else min(n_answers, 20 * len(g))
            tt = token_profile(g)
            cost = usd(tt, p)
            per_unit.append({"run": m["run_id"] + (" (in progress)" if m.get("in_progress") else ""), "model": m["model"], "effort": m["effort"], "task": task, "label": label,
                             "n_units": n_units, "calls": tt["calls"], "cost": cost, "cost_per_unit": cost / n_units,
                             "out_per_unit": tt["output"] / n_units, "think_per_unit": tt["thinking"] / n_units,
                             "cache_read_per_call": tt["cache_read"] / tt["calls"], "wall_min": m.get(f"wall_clock_min_{task}"),
                             "prices": p, "tokens": tt})
    lines += ["", "## Per-unit cost by task", "",
              "| Run | Task | Units | Calls | Cost | Cost per unit | Output tokens per unit (thinking) | Cached tokens read per call | Wall-clock (4 workers) |",
              "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for x in per_unit:
        lines.append(f"| `{x['run']}` | {x['task']} | {x['n_units']} | {x['calls']} | ${x['cost']:.2f} | ${x['cost_per_unit']:.4f} {x['label']} | "
                     f"{x['out_per_unit']:.0f} ({x['think_per_unit']:.0f}) | {fmt_tokens(x['cache_read_per_call'])} | {x['wall_min']:.0f} min |")

    lines += ["", "## Where the money goes", ""]
    for x in per_unit:
        tt, p = x["tokens"], x["prices"]
        parts = {"uncached input": tt["input"] * p["input"], "cache writes": tt["cache_write"] * p["cache_write"],
                 "cache reads": tt["cache_read"] * p["cache_read"], "output incl. thinking": tt["output"] * p["output"]}
        tot = sum(parts.values())
        shares = ", ".join(f"{k} {v / tot:.0%}" for k, v in parts.items())
        lines.append(f"- `{x['run']}`, {x['task']}: {shares}.")

    lines += ["", "## Projection to the 1M-conversation scale", "",
              "Open-ended answers are the unit that scales. The per-answer figures below reuse the measured token "
              "shape (cached codebook read once per 20-answer call, observed output and thinking tokens per answer) "
              "at list prices. Message Batches (50% off) is not available on Bedrock, so no batch discount is applied.",
              "",
              "| Model (effort) | Measured cost per answer | Per 1,000 answers | Per 100,000 | Per 1,000,000 |",
              "|---|---:|---:|---:|---:|"]
    oe = [x for x in per_unit if x["task"] == "open_ended"]
    for x in oe:
        c = x["cost_per_unit"]
        lines.append(f"| {x['model']} ({x['effort']}) | ${c:.4f} | ${c * 1e3:,.0f} | ${c * 1e5:,.0f} | ${c * 1e6:,.0f} |")
    # Models not run: scale the measured token shape of the closest run by that model's prices.
    ran = {coder.price_key(x["model"]) for x in oe}
    ref = max(oe, key=lambda x: PRICES[coder.price_key(x["model"])]["output"]) if oe else None
    for key, p in PRICES.items():
        if key in ran or ref is None:
            continue
        tt = ref["tokens"]
        c = usd(tt, p) / ref["n_units"]
        lines.append(f"| {key} (not run; token shape of {ref['model']} at {key} prices) | ${c:.4f} | ${c * 1e3:,.0f} | ${c * 1e5:,.0f} | ${c * 1e6:,.0f} |")

    lines += ["", "## Notes", "",
              "- Thinking tokens are billed as output tokens; the thinking column is a subset of output.",
              "- A run marked in progress is read from its saved responses; its per-unit figures cover the units coded so far and its total is not a full-run cost.",
              "- The runs coded 2,058 answer passages because 60 answers delivered in two survey exports were in the input twice; the per-answer figures divide by the 1,998 distinct answers, so they carry about 3% of duplicate overhead.",
              "- Cache reads cost 0.1x input on Sonnet 5, 0.05x on Opus 5.5, 0.025x on Fable 5.1; cache writes cost 1.25x. "
              "The codebook (about 19K tokens) is written once per task per run and read on every call.",
              "- Wall-clock is the span between the first and last saved response with 4 concurrent requests; the transcript and answer tasks ran one after the other.",
              "- Fable 5.1 could not be run: Bedrock returns `data retention mode 'default' is not available for this model` "
              "until the account's Bedrock data-retention setting is changed, and the Mantle endpoint returns 404 for it. "
              "Opus 5.5 is reachable only through the legacy InvokeModel path with the `global.` inference profile; the Mantle "
              "endpoint returns 403 (`aws-marketplace:Subscribe` not authorized for this IAM user).",
              "- The Opus 5.5 run folder also holds `raw_resume_aborted/`: 17 responses from a `--resume` started after the input file had changed, which re-coded moved batches before it was stopped (about $3, not in the figures above). The coder now refuses to resume when the inputs differ.",
              "- Rows per run and the hand review of coding quality are in `scripts/nlp/PLAN-llm-coding.md` under Findings.",
              ""]
    OUT.write_text("\n".join(lines))
    print(f"wrote {OUT} ({len(runs)} runs)")


if __name__ == "__main__":
    main()
