"""Apply the IMCC codebook to interview transcripts and open-ended answers with Claude
on Amazon Bedrock, recording every token so a run can be costed.

Usage
-----
  python scripts/nlp/02_code-text.py --model anthropic.claude-sonnet-5 --limit 5      # smoke test
  python scripts/nlp/02_code-text.py --model anthropic.claude-sonnet-5                # full run
  python scripts/nlp/02_code-text.py --model global.anthropic.claude-opus-5-5         # legacy endpoint
  python scripts/nlp/02_code-text.py --model anthropic.claude-fable-5-1 --tasks open_ended
  python scripts/nlp/02_code-text.py --model anthropic.claude-sonnet-5 --resume            # finish an interrupted run (same inputs only)

Model IDs without a region prefix (`anthropic.claude-sonnet-5`) go to the Claude in
Amazon Bedrock endpoint (`AnthropicBedrockMantle`). IDs with a `global.` or `us.`
prefix are cross-region inference profiles and go through the legacy InvokeModel client
(`AnthropicBedrock`); the request body is the same. Region comes from AWS_REGION /
AWS_DEFAULT_REGION, credentials from the usual AWS chain. Nothing is hard-coded.

Inputs (all under data/, gitignored)
  data/processed/codebook.csv                 from 00_ingest-codebook.R (v6)
  data/raw/interview-transcripts/*.docx       pandoc must be on PATH
  data/processed/open_ended.csv               from 01_open-ended.R

Outputs: data/processed/llm-coding/<run_id>/
  manifest.json          model, endpoint, effort, prompt SHA-1s, totals, cost estimate
  usage.csv              one row per API call with every token count and latency
  coded_transcripts.csv  one row per segment x code (same columns as the pilot CSV)
  coded_open_ended.csv   one row per answer x code
  raw/*.json             raw API responses, so nothing has to be re-run to inspect
  system_prompt_*.md     the rendered system prompts, for the record
plus data/processed/llm-coding/segments.csv, the transcript unit table (run-independent).

Prompts live in scripts/nlp/coding_prompt.md and scripts/nlp/prompts/ (see the README
there). The tool schema below (`SUBMIT_TOOL`) is the only prompt text in this file.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Literal

import anthropic
import pandas as pd
from anthropic import AnthropicBedrock, AnthropicBedrockMantle
from pydantic import BaseModel, ValidationError

ROOT = Path(__file__).resolve().parents[2]
PROMPTS = ROOT / "scripts" / "nlp" / "prompts"
RULES_FILE = ROOT / "scripts" / "nlp" / "coding_prompt.md"
CODEBOOK = ROOT / "data" / "processed" / "codebook.csv"
OPEN_ENDED = ROOT / "data" / "processed" / "open_ended.csv"
TRANSCRIPTS = ROOT / "data" / "raw" / "interview-transcripts"
OUT_ROOT = ROOT / "data" / "processed" / "llm-coding"

# List prices, USD per million tokens, Anthropic first-party rates as published at
# https://platform.claude.com/docs/en/about-claude/pricing (read 2026-10-06). Amazon
# Bedrock bills these models at the same list rates on global endpoints and adds 10% on
# regional (`us.`) endpoints; AWS's own pricing page did not list these models when
# checked, so reconcile against the AWS bill after a run.
PRICES = {
    "claude-sonnet-5":  {"input": 2.00,  "cache_write": 2.50,  "cache_read": 0.20, "output": 10.00},
    "claude-opus-5-5":  {"input": 4.00,  "cache_write": 5.00,  "cache_read": 0.20, "output": 20.00},
    "claude-opus-5":    {"input": 5.00,  "cache_write": 6.25,  "cache_read": 0.50, "output": 25.00},
    "claude-fable-5-1": {"input": 10.00, "cache_write": 12.50, "cache_read": 0.25, "output": 50.00},
}
PRICE_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing (2026-10-06)"

# ---- tool schemas (the structured-output contract) -----------------------------------
# Structured outputs (`output_config.format`) and `strict` tools are not available on
# Bedrock, so the schema is enforced client-side with pydantic after the call.

CODE_ITEM = {
    "type": "object",
    "properties": {
        "code": {"type": "string", "description": "A code name from the codebook, copied exactly."},
        "excerpt": {"type": "string", "description": "Shortest verbatim span from the passage supporting the code."},
        "rationale": {"type": "string", "description": "One sentence under 20 words referencing the codebook definition."},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
    },
    "required": ["code", "excerpt", "rationale", "confidence"],
    "additionalProperties": False,
}

SUBMIT_TOOL = {
    "name": "submit_codes",
    "description": "Submit the codes for every passage you were asked to code, one entry per passage_id.",
    "input_schema": {
        "type": "object",
        "properties": {
            "passages": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "passage_id": {"type": "string", "description": "Copied exactly from the request."},
                        "codes": {"type": "array", "items": CODE_ITEM, "description": "Empty when no code applies."},
                        "possible_new_code": {"type": "string", "description": "Proposed code name and definition; only when an _OTHER code was used."},
                    },
                    "required": ["passage_id", "codes"],
                    "additionalProperties": False,
                },
            }
        },
        "required": ["passages"],
        "additionalProperties": False,
    },
}


class CodeItem(BaseModel):
    code: str
    excerpt: str
    rationale: str
    confidence: Literal["high", "medium", "low"]


class CodedPassage(BaseModel):
    passage_id: str
    codes: list[CodeItem]
    possible_new_code: str | None = None


class Submission(BaseModel):
    passages: list[CodedPassage]


def repair(raw: dict) -> dict:
    """Undo the one malformation seen in practice: `passages` sent as a JSON string
    (sometimes wrapping the whole object again) instead of a list."""
    for _ in range(2):
        v = raw.get("passages") if isinstance(raw, dict) else None
        if isinstance(v, str):
            try:
                v = json.loads(v)
            except json.JSONDecodeError:
                return raw
            raw = v if isinstance(v, dict) and "passages" in v else {**raw, "passages": v}
        else:
            break
    return raw


# ---- inputs ----------------------------------------------------------------------------

def sha1(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def read_codebook() -> tuple[pd.DataFrame, str]:
    cb = pd.read_csv(CODEBOOK, dtype=str).fillna("")
    cols = ["domain", "parent", "code", "definition", "include", "exclude", "keywords"]
    rows = ["| Domain | Parent | Code | Definition | Include | Exclude | Keywords |", "|---|---|---|---|---|---|---|"]
    for _, r in cb.iterrows():
        rows.append("| " + " | ".join(r[c].replace("|", "/").replace("\n", " ") for c in cols) + " |")
    return cb, "\n".join(rows)


def docx_to_lines(path: Path) -> list[str]:
    out = subprocess.run(["pandoc", str(path), "-t", "plain", "--wrap=none"], check=True, capture_output=True, text=True)
    return [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]


# Speaker labels seen across the delivered formats: "Facilitator: [00:00:00] text",
# "PARTICIPANT: text", "Interviewee: text", "-   [PARTICIPANT 9] (reframing ...): text".
# Restricting the label vocabulary keeps "I told him: no" inside a turn from starting one.
LABEL = re.compile(
    r"^(?:-\s+)?\[?(?P<spk>(?:facilitator|interviewer|interviewee|participant|translator|moderator|unknown speaker|note taker)[A-Za-z0-9 /]{0,20}?)\]?"
    r"(?:\s*\([^)]{0,80}\))?\s*:\s*(?P<rest>.*)$",
    re.IGNORECASE,
)
NUMBERED = re.compile(r"^\d{1,2}\.\s+")                 # facilitator questions / roster in the notes-style file
TIMESTAMP = re.compile(r"\[\d{1,2}:\d{2}:\d{2}\]\s*")
NOT_PARTICIPANT = re.compile(r"^(facilitator|interviewer|translator|moderator|question)", re.IGNORECASE)


def segment_transcript(path: Path) -> tuple[str, pd.DataFrame]:
    """One row per participant turn; the whole letter is one row. Returns (full_text, turns)."""
    stem = path.stem.strip()
    lines = docx_to_lines(path)
    full_text = "\n".join(TIMESTAMP.sub("", ln) for ln in lines)
    turns: list[dict] = []
    for ln in lines:
        m = LABEL.match(ln)
        if m:
            turns.append({"speaker": m.group("spk").strip(), "text": [TIMESTAMP.sub("", m.group("rest"))]})
        elif NUMBERED.match(ln):
            turns.append({"speaker": "question", "text": [NUMBERED.sub("", ln)]})
        elif turns:
            turns[-1]["text"].append(TIMESTAMP.sub("", ln))
    n_labelled = sum(1 for t in turns if t["speaker"] != "question")
    if n_labelled < 5:                                      # a written letter: no turns, one segment
        df = pd.DataFrame([{"file": stem, "speaker": "letter", "text": full_text}])
    else:
        df = pd.DataFrame([{"file": stem, "speaker": t["speaker"], "text": " ".join(t["text"]).strip()} for t in turns])
        df = df[~df["speaker"].str.match(NOT_PARTICIPANT) & (df["text"].str.len() >= 40)].reset_index(drop=True)
    df.insert(0, "segment_id", [f"{stem}_{i + 1:03d}" for i in range(len(df))])
    return full_text, df


# ---- client ----------------------------------------------------------------------------

def make_client(model: str):
    """Mantle endpoint for bare `anthropic.` IDs; legacy InvokeModel for inference profiles."""
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if not region:
        sys.exit("Set AWS_REGION (or AWS_DEFAULT_REGION).")
    if model.startswith(("global.", "us.", "eu.", "apac.", "jp.")):
        return AnthropicBedrock(aws_region=region, max_retries=5), "bedrock-invokemodel", region
    return AnthropicBedrockMantle(aws_region=region, max_retries=5), "bedrock-mantle", region


def price_key(model: str) -> str | None:
    for key in PRICES:
        if key in model:
            return key
    return None


class Coder:
    def __init__(self, args, cb: pd.DataFrame, codebook_md: str):
        self.args = args
        self.cb = cb
        self.codes = set(cb["code"])
        self.norm_codes = {re.sub(r"[^A-Z0-9]", "", c.upper()): c for c in self.codes}
        self.client, self.endpoint, self.region = make_client(args.model)
        self.rules = RULES_FILE.read_text()
        self.codebook_md = codebook_md
        self.usage_rows: list[dict] = []
        self.run_id = f"{date.today():%Y%m%d}_{re.sub(r'[^a-z0-9]+', '-', args.model.split('anthropic.')[-1])}_{args.effort}"
        self.out = OUT_ROOT / self.run_id
        if self.out.exists() and not args.resume and any((self.out / "raw").glob("*.json")):
            sys.exit(f"{self.out} already has responses; pass --resume to reuse them or delete the folder")
        (self.out / "raw").mkdir(parents=True, exist_ok=True)
        self.prev_latency = {}
        self.input_sha1 = {"open_ended.csv": sha1(OPEN_ENDED.read_text()) if OPEN_ENDED.exists() else None,
                           "transcripts": sha1("".join(sorted(f.name for f in TRANSCRIPTS.glob("*.docx"))))}
        if args.resume and (self.out / "usage.csv").exists():      # keep the latencies the original calls recorded
            prev = pd.read_csv(self.out / "usage.csv")
            self.prev_latency = dict(zip(prev.call_id, prev.latency_s))
        if args.resume and (self.out / "manifest.json").exists():
            prev_m = json.loads((self.out / "manifest.json").read_text())
            if prev_m.get("input_sha1") and prev_m["input_sha1"] != self.input_sha1:
                sys.exit("the input files changed since this run was made; a resume would re-code the units whose "
                         "batches moved (new API calls). Start a new run instead, or restore the original inputs.")

    def system(self, task: str) -> list[dict]:
        task_md = (PROMPTS / f"task_{task}.md").read_text()
        return [
            {"type": "text", "text": self.rules + "\n\n" + task_md},
            {"type": "text", "text": "## Codebook\n\n" + self.codebook_md, "cache_control": {"type": "ephemeral"}},
        ]

    def call(self, call_id: str, task: str, system: list[dict], content: list[dict], tool: dict) -> dict | None:
        t0 = time.time()
        row = {"call_id": call_id, "task": task, "model": self.args.model, "effort": self.args.effort}
        raw_path = self.out / "raw" / f"{call_id}.json"
        if self.args.resume and raw_path.exists():          # reuse a saved response instead of paying again
            resp = anthropic.types.Message.model_validate_json(raw_path.read_text())
            t0 = None
        else:
            resp = None
        try:
            if resp is None:
                resp = self.client.messages.create(
                    model=self.args.model,
                    max_tokens=self.args.max_tokens,
                    thinking={"type": "adaptive"},
                    output_config={"effort": self.args.effort},
                    system=system,
                    tools=[tool],
                    tool_choice={"type": "auto"},      # forced tool choice is rejected on Opus 5.5 / Fable 5.1
                    messages=[{"role": "user", "content": content}],
                )
        except anthropic.APIStatusError as e:
            row.update(status=f"error {e.status_code}", error=str(e)[:300], latency_s=round(time.time() - t0, 1))
            self.usage_rows.append(row)
            return None
        u = resp.usage
        details = getattr(u, "output_tokens_details", None)
        row.update(
            status=resp.stop_reason,
            input_tokens=u.input_tokens,
            cache_creation_input_tokens=u.cache_creation_input_tokens or 0,
            cache_read_input_tokens=u.cache_read_input_tokens or 0,
            output_tokens=u.output_tokens,
            thinking_tokens=getattr(details, "thinking_tokens", None),
            latency_s=round(time.time() - t0, 1) if t0 else self.prev_latency.get(call_id),
            resumed=t0 is None,
        )
        if t0:
            raw_path.write_text(resp.model_dump_json(indent=1))
        tool_use = next((b for b in resp.content if b.type == "tool_use"), None)
        if resp.stop_reason == "refusal" or tool_use is None:
            row["error"] = f"no tool call (stop_reason={resp.stop_reason})"
            self.usage_rows.append(row)
            return None
        self.usage_rows.append(row)
        return repair(tool_use.input)

    def check_code(self, code: str) -> tuple[str, bool]:
        """Exact match, else a normalised match (case, underscores), else flagged unknown."""
        if code in self.codes:
            return code, True
        hit = self.norm_codes.get(re.sub(r"[^A-Z0-9]", "", code.upper()))
        return (hit, True) if hit else (code, False)

    def rows_from(self, codes: list[CodeItem], ids: dict, possible_new_code: str | None) -> list[dict]:
        rows = []
        for c in codes:
            code, known = self.check_code(c.code)
            cb_row = self.cb[self.cb["code"] == code].iloc[0] if known else None
            rows.append({**ids, "code": code, "excerpt": c.excerpt, "rationale": c.rationale, "confidence": c.confidence,
                         "domain": cb_row["domain"] if known else None, "parent_code": cb_row["parent"] if known else None,
                         "in_codebook": known, "possible_new_code": possible_new_code,
                         "model": self.args.model, "effort": self.args.effort, "run_date": date.today().isoformat()})
        return rows

    # ---- task 1: transcripts ------------------------------------------------------------

    def code_transcripts(self, limit: int | None) -> pd.DataFrame:
        files = sorted(TRANSCRIPTS.glob("*.docx"))
        texts, seg_frames = {}, []
        for f in files:
            text, segs = segment_transcript(f)
            texts[segs["file"].iloc[0]] = text
            seg_frames.append(segs)
        segments = pd.concat(seg_frames, ignore_index=True)
        OUT_ROOT.mkdir(parents=True, exist_ok=True)
        segments.to_csv(OUT_ROOT / "segments.csv", index=False)
        todo = segments.head(limit) if limit else segments
        print(f"transcripts: {len(files)} files, {len(segments)} participant segments, coding {len(todo)}")

        system = self.system("transcript")
        (self.out / "system_prompt_transcript.md").write_text("\n\n".join(b["text"] for b in system))
        template = (PROMPTS / "user_transcript.md").read_text()

        def one(seg) -> list[dict]:
            content = [
                {"type": "text", "text": "## Full transcript (context only)\n\n" + texts[seg.file], "cache_control": {"type": "ephemeral"}},
                {"type": "text", "text": template.format(segment_id=seg.segment_id, speaker=seg.speaker, text=seg.text)},
            ]
            raw = self.call(seg.segment_id, "transcript", system, content, SUBMIT_TOOL)
            if raw is None:
                return []
            try:
                parsed = Submission.model_validate(raw).passages
            except ValidationError as e:
                print(f"  {seg.segment_id}: schema violation ({str(e)[:120]})")
                return []
            got = next((p for p in parsed if p.passage_id == seg.segment_id), parsed[0] if parsed else None)
            if got is None:
                print(f"  {seg.segment_id}: empty submission")
                return []
            ids = {"segment_id": seg.segment_id, "file": seg.file, "speaker": seg.speaker}
            return self.rows_from(got.codes, ids, got.possible_new_code)

        # Warm the cache once per transcript so parallel calls read rather than all write.
        rows: list[dict] = []
        first_per_file = todo.groupby("file").head(1)
        for seg in first_per_file.itertuples():
            rows += one(seg)
        rest = todo[~todo.segment_id.isin(first_per_file.segment_id)]
        with ThreadPoolExecutor(self.args.workers) as pool:
            for r in pool.map(one, rest.itertuples()):
                rows += r
        return pd.DataFrame(rows)

    # ---- task 2: open-ended answers ----------------------------------------------------

    def code_open_ended(self, limit: int | None) -> pd.DataFrame:
        oe = pd.read_csv(OPEN_ENDED, dtype=str).dropna(subset=["text"]).sort_values("answer_id")
        todo = oe.head(limit) if limit else oe
        print(f"open-ended: {len(oe)} answers, coding {len(todo)}")
        system = self.system("open_ended")
        (self.out / "system_prompt_open_ended.md").write_text("\n\n".join(b["text"] for b in system))
        template = (PROMPTS / "user_open_ended.md").read_text()

        def batches(df: pd.DataFrame, size: int):
            for (tool, question), grp in df.groupby(["tool", "question"], sort=True):
                for i in range(0, len(grp), size):
                    yield tool, question, grp.iloc[i:i + size]

        def one(batch) -> tuple[list[dict], list[str]]:
            tool, question, grp = batch
            answers = "\n\n".join(
                f"### passage_id: {a.answer_id}\npathway: {a.pathway if isinstance(a.pathway, str) else 'unknown'}\n\n{a.text}"
                for a in grp.itertuples())
            content = [{"type": "text", "text": template.format(tool=tool, question=question, question_text=grp.question_text.iloc[0], answers=answers)}]
            call_id = f"batch_{grp.answer_id.iloc[0]}".replace(" ", "-")
            raw = self.call(call_id, "open_ended", system, content, SUBMIT_TOOL)
            if raw is None:
                return [], list(grp.answer_id)
            try:
                parsed = Submission.model_validate(raw)
            except ValidationError as e:
                print(f"  {call_id}: schema violation ({str(e)[:120]})")
                return [], list(grp.answer_id)
            by_id = {p.passage_id: p for p in parsed.passages}
            rows, missing = [], []
            for a in grp.itertuples():
                got = by_id.get(a.answer_id)
                if got is None:
                    missing.append(a.answer_id)
                    continue
                ids = {"answer_id": a.answer_id, "tool": tool, "question": question}
                rows += self.rows_from(got.codes, ids, got.possible_new_code)
                if not got.codes:
                    rows.append({**ids, "code": None, "excerpt": None, "rationale": None, "confidence": None, "domain": None,
                                 "parent_code": None, "in_codebook": None, "possible_new_code": got.possible_new_code,
                                 "model": self.args.model, "effort": self.args.effort, "run_date": date.today().isoformat()})
            return rows, missing

        rows: list[dict] = []
        all_batches = list(batches(todo, self.args.batch_size))
        first, rest = all_batches[:1], all_batches[1:]          # warm the codebook cache first
        r, missing = one(first[0])
        rows += r
        with ThreadPoolExecutor(self.args.workers) as pool:
            for r, m in pool.map(one, rest):
                rows += r
                missing += m
        if missing:                                            # second pass, small batches, for answers a batch skipped
            print(f"  {len(missing)} answers missing from batch replies; retrying in batches of 5")
            retry = todo[todo.answer_id.isin(missing)]
            still = []
            for b in batches(retry, 5):
                r, m = one(b)
                rows += r
                still += m
            if still:
                print(f"  still uncoded after retry: {len(still)} answers")
        return pd.DataFrame(rows)

    # ---- bookkeeping ---------------------------------------------------------------------

    def cost(self, usage: pd.DataFrame) -> dict | None:
        key = price_key(self.args.model)
        if key is None or usage.empty:
            return None
        p = PRICES[key]
        ok = usage[usage["status"].isin(["tool_use", "end_turn", "max_tokens", "refusal"])]
        tot = {c: int(ok[c].fillna(0).sum()) for c in ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]}
        tot["thinking_tokens"] = int(ok["thinking_tokens"].fillna(0).sum()) if "thinking_tokens" in ok else None
        usd = (tot["input_tokens"] * p["input"] + tot["cache_creation_input_tokens"] * p["cache_write"]
               + tot["cache_read_input_tokens"] * p["cache_read"] + tot["output_tokens"] * p["output"]) / 1e6
        by_task = {}
        for task, g in ok.groupby("task"):
            by_task[task] = round((g["input_tokens"].sum() * p["input"] + g["cache_creation_input_tokens"].sum() * p["cache_write"]
                                   + g["cache_read_input_tokens"].sum() * p["cache_read"] + g["output_tokens"].sum() * p["output"]) / 1e6, 4)
        return {"price_key": key, "prices_usd_per_mtok": p, "price_source": PRICE_SOURCE, "tokens": tot,
                "usd_total": round(usd, 4), "usd_by_task": by_task, "calls": int(len(usage)), "calls_ok": int(len(ok))}

    def finish(self, started: str, coded: dict[str, pd.DataFrame]):
        usage = pd.DataFrame(self.usage_rows)
        usage.to_csv(self.out / "usage.csv", index=False)
        for task, df in coded.items():
            df.to_csv(self.out / f"coded_{task}.csv", index=False)
        manifest = {
            "run_id": self.run_id, "started": started, "finished": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "model": self.args.model, "endpoint": self.endpoint, "region": self.region,
            "thinking": "adaptive", "effort": self.args.effort, "max_tokens": self.args.max_tokens,
            "batch_size_open_ended": self.args.batch_size, "limit": self.args.limit, "tasks": self.args.tasks,
            "sdk": f"anthropic {anthropic.__version__}", "python": platform.python_version(),
            "prompt_sha1": {"coding_prompt.md": sha1(self.rules),
                            **{p.name: sha1(p.read_text()) for p in sorted(PROMPTS.glob("*.md")) if p.name != "README.md"},
                            "codebook_table": sha1(self.codebook_md)},
            "input_sha1": self.input_sha1,
            "codebook_version": self.cb["version"].iloc[0] if "version" in self.cb else None,
            "codebook_rows": int(len(self.cb)),
            "n_coded_rows": {task: int(len(df)) for task, df in coded.items()},
            "cost_estimate": self.cost(usage),
        }
        (self.out / "manifest.json").write_text(json.dumps(manifest, indent=2))
        print(json.dumps({k: manifest[k] for k in ["run_id", "endpoint", "n_coded_rows", "cost_estimate"]}, indent=1))
        print("wrote", self.out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="Bedrock model ID, e.g. anthropic.claude-sonnet-5 or global.anthropic.claude-opus-5-5")
    ap.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
    ap.add_argument("--max-tokens", type=int, default=16000)
    ap.add_argument("--tasks", default="transcripts,open_ended", help="comma-separated subset of transcripts,open_ended")
    ap.add_argument("--limit", type=int, default=None, help="code only the first N units of each task (smoke test)")
    ap.add_argument("--batch-size", type=int, default=20, help="open-ended answers per call")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--resume", action="store_true", help="reuse saved raw/*.json responses from an earlier run with the same run_id")
    args = ap.parse_args()

    cb, codebook_md = read_codebook()
    coder = Coder(args, cb, codebook_md)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"run {coder.run_id}: {args.model} via {coder.endpoint} ({coder.region}), effort {args.effort}, codebook v{cb['version'].iloc[0]} ({len(cb)} codes)")
    coded = {}
    tasks = args.tasks.split(",")
    try:
        if "transcripts" in tasks:
            coded["transcripts"] = coder.code_transcripts(args.limit)
        if "open_ended" in tasks:
            coded["open_ended"] = coder.code_open_ended(args.limit)
    finally:
        coder.finish(started, coded)


if __name__ == "__main__":
    main()
