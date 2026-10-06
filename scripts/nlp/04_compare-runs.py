"""Compare two coding runs unit by unit and write the hand-review file for each.

  python scripts/nlp/04_compare-runs.py 20261006_claude-sonnet-5_medium 20261006_claude-opus-5-5_medium
  python scripts/nlp/04_compare-runs.py 20261006_claude-sonnet-5_medium        # review files only

Writes, under data/processed/llm-coding/ (gitignored, they quote passages):
  compare_<a>_vs_<b>.md       agreement tables (per task, per domain), zero-overlap units
  <run>/review_transcripts.md  every segment with its text, then each assignment with the
  <run>/review_open_ended.md   codebook definition, exclude rule, excerpt, rationale

Agreement is symmetric Jaccard per unit plus "recall/precision" of run B against run A,
reported for what they are: two machine coders agreeing with each other, not validity.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / "data" / "processed" / "llm-coding"
CB = pd.read_csv(ROOT / "data" / "processed" / "codebook.csv", dtype=str).fillna("").set_index("code")


def load(run: str) -> dict[str, pd.DataFrame]:
    d = RUNS / run
    out = {}
    for task, key in [("transcripts", "segment_id"), ("open_ended", "answer_id")]:
        f = d / f"coded_{task}.csv"
        if f.exists() and f.stat().st_size > 1:
            df = pd.read_csv(f, dtype=str)
            df["unit"] = df[key]
            out[task] = df
    return out


def code_sets(df: pd.DataFrame) -> pd.Series:
    return df.dropna(subset=["code"]).groupby("unit")["code"].agg(lambda s: frozenset(s))


def compare(a: pd.DataFrame, b: pd.DataFrame, units: pd.Index) -> dict:
    sa, sb = code_sets(a), code_sets(b)
    rows = []
    for u in units:
        A, B = sa.get(u, frozenset()), sb.get(u, frozenset())
        inter, union = len(A & B), len(A | B)
        rows.append({"unit": u, "n_a": len(A), "n_b": len(B), "inter": inter,
                     "jaccard": inter / union if union else 1.0, "both_empty": not A and not B})
    r = pd.DataFrame(rows)
    tp = r.inter.sum()
    return {"units": len(r), "jaccard_mean": r.jaccard.mean(), "exact_match": (r.jaccard == 1).mean(),
            "codes_a": r.n_a.sum(), "codes_b": r.n_b.sum(), "overlap": tp,
            "recall_b_vs_a": tp / r.n_a.sum() if r.n_a.sum() else float("nan"),
            "precision_b_vs_a": tp / r.n_b.sum() if r.n_b.sum() else float("nan"),
            "zero_overlap": r[(r.inter == 0) & ~r.both_empty], "per_unit": r}


def domain_table(a: pd.DataFrame, b: pd.DataFrame) -> pd.DataFrame:
    def by_dom(df):
        df = df.dropna(subset=["code"])
        return df.groupby("domain").agg(assignments=("code", "size"), units=("unit", "nunique"))
    da, db = by_dom(a), by_dom(b)
    both = a.dropna(subset=["code"]).merge(b.dropna(subset=["code"]), on=["unit", "code"])
    agree = both.groupby("domain_x").size().rename("same_code_same_unit")
    return pd.concat([da.add_suffix("_a"), db.add_suffix("_b"), agree], axis=1).fillna(0).astype(int)


def review_file(run: str, task: str, df: pd.DataFrame, texts: pd.Series, out: Path):
    lines = [f"# Review: {run}, {task}", "", f"{df.unit.nunique()} units, {df.code.notna().sum()} assignments", ""]
    for u, g in df.groupby("unit", sort=True):
        lines += [f"## {u}", "", texts.get(u, "(text not found)").strip(), ""]
        for _, r in g.iterrows():
            if pd.isna(r.code):
                lines.append("- (no code)")
                continue
            cb = CB.loc[r.code] if r.code in CB.index else None
            lines.append(f"- **{r.code}** [{r.confidence}] — “{r.excerpt}”")
            lines.append(f"    - rationale: {r.rationale}")
            if cb is not None:
                lines.append(f"    - def: {cb.definition} | exclude: {cb.exclude}")
            else:
                lines.append("    - NOT IN CODEBOOK")
            if isinstance(r.get("possible_new_code"), str):
                lines.append(f"    - possible_new_code: {r.possible_new_code}")
        lines.append("")
    out.write_text("\n".join(lines))


def main(run_a: str, run_b: str | None):
    segments = pd.read_csv(RUNS / "segments.csv", dtype=str).set_index("segment_id")["text"]
    answers = pd.read_csv(ROOT / "data" / "processed" / "open_ended.csv", dtype=str).set_index("answer_id")["text"]
    texts = {"transcripts": segments, "open_ended": answers[~answers.index.duplicated()]}
    A = load(run_a)
    if run_b is None:
        for task, df in A.items():
            review_file(run_a, task, df, texts[task], RUNS / run_a / f"review_{task}.md")
            print("wrote", RUNS / run_a / f"review_{task}.md")
        return
    B = load(run_b)
    md = [f"# {run_a} vs {run_b}", ""]
    for task in ["transcripts", "open_ended"]:
        if task not in A or task not in B:
            continue
        a, b = A[task], B[task]
        units = pd.Index(sorted(set(a.unit) | set(b.unit)))
        c = compare(a, b, units)
        md += [f"## {task}", "",
               "| Metric | Value |", "|---|---:|",
               f"| Units coded by either run | {c['units']} |",
               f"| Assignments, run A | {c['codes_a']} |", f"| Assignments, run B | {c['codes_b']} |",
               f"| Same code on same unit | {c['overlap']} |",
               f"| Mean per-unit Jaccard | {c['jaccard_mean']:.2f} |",
               f"| Units with identical code sets | {c['exact_match']:.0%} |",
               f"| Recall of B vs A | {c['recall_b_vs_a']:.0%} |", f"| Precision of B vs A | {c['precision_b_vs_a']:.0%} |",
               "", "### By domain", "", domain_table(a, b).to_markdown(), ""]
        uncoded = {k: (code_sets(df).reindex(units).isna()).mean() for k, df in [("A", a), ("B", b)]}
        md += [f"Units with no code: A {uncoded['A']:.0%}, B {uncoded['B']:.0%}.", ""]
        top = pd.concat([a.code.value_counts().rename("A"), b.code.value_counts().rename("B")], axis=1).fillna(0).astype(int)
        top["diff"] = top.A - top.B
        md += ["### Codes used most differently (A minus B)", "", top.reindex(top["diff"].abs().sort_values(ascending=False).index).head(20).to_markdown(), ""]
        z = c["zero_overlap"]
        md += [f"### Zero-overlap units ({len(z)})", ""]
        sa, sb = code_sets(a), code_sets(b)
        for u in z.unit.head(40):
            md.append(f"- `{u}`: A = {sorted(sa.get(u, []))} | B = {sorted(sb.get(u, []))}")
        md.append("")
        for run, df in [(run_a, a), (run_b, b)]:
            review_file(run, task, df, texts[task], RUNS / run / f"review_{task}.md")
    out = RUNS / f"compare_{run_a}_vs_{run_b}.md"
    out.write_text("\n".join(md))
    print("wrote", out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
