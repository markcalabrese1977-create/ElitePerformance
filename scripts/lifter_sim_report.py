#!/usr/bin/env python3
"""Aggregates LifterSimulationTests output into one table per profile x variant (columns: the two templates)."""
import json, sys, collections, glob

PROFILES = ["accurate", "typical", "all-zero", "effort-off"]
VARIANTS = ["shipped", "no-lifter-rule", "valve-total", "count-first3", "rir-tol1"]
TEMPLATES = [("dup12", "12-Week DUP"), ("ul5", "5-Day Upper/Lower")]
NUM = ("track_n track_sum track_sumsq fp_n decisions increases lowers holds hold_rirAdj hold_repsShort hold_other valve h2i_n h2i_sum "
       "h2i_censored final_n final_ratio final_vs_ideal start_n start_vs_ideal start_fp start_e1_ratio start_ideal_ratio").split()

def load(paths):
    cells = collections.defaultdict(lambda: collections.defaultdict(float))
    lifters = collections.defaultdict(int); failed = collections.Counter(); secs = 0.0
    for p in paths:
        for line in open(p):
            line = line.strip()
            if not line: continue
            d = json.loads(line); a = d["acc"]; k = (d["template"], d["profile"], d["variant"])
            if a.get("failed"): failed[k] += 1
            lifters[k] += 1; secs += a.get("seconds", 0)
            c = cells[k]
            for n in NUM: c[n] += a.get(n, 0)
            for i in range(4):
                c[f"q_n{i}"] += a["q_n"][i]; c[f"q_sum{i}"] += a["q_sum"][i]; c[f"q_fp{i}"] += a["q_fp"][i]
    return cells, lifters, failed, secs

def pct(x): return f"{100*x:.1f}%"
def div(a, b): return a / b if b else float("nan")

def rows(c, n):
    r = []
    mean = div(c["track_sum"], c["track_n"])
    rms = (div(c["track_sumsq"], c["track_n"])) ** 0.5
    r.append(("lifter-blocks", str(n)))
    r.append(("compound exposures with a planned load", f"{int(c['track_n'])}"))
    r.append(("tracking error, mean (planned / ideal load - 1)", pct(mean)))
    r.append(("tracking error, RMS", pct(rms)))
    r.append(("tracking error by block quarter (Q1 / Q2 / Q3 / Q4)", " / ".join(pct(div(c[f"q_sum{i}"], c[f"q_n{i}"])) for i in range(4))))
    r.append(("planned above what the lifter could do for repMin (false positive)", pct(div(c["fp_n"], c["track_n"]))))
    r.append(("  by quarter", " / ".join(pct(div(c[f"q_fp{i}"], c[f"q_n{i}"])) for i in range(4))))
    d = c["decisions"]
    r.append(("decisions: increase / hold / lower", f"{pct(div(c['increases'], d))} / {pct(div(c['holds'], d))} / {pct(div(c['lowers'], d))}"))
    h = c["holds"]
    r.append(("holds by cause: RIR adjustment / reps short / other", f"{pct(div(c['hold_rirAdj'], d))} / {pct(div(c['hold_repsShort'], d))} / {pct(div(c['hold_other'], d))} of decisions"))
    r.append(("valve releases", f"{int(c['valve'])} ({pct(div(c['valve'], d))} of decisions, {div(c['valve'], n):.2f} per lifter-block)"))
    r.append(("exposures from a hold to the next increase (same lift and letter), mean", f"{div(c['h2i_sum'], c['h2i_n']):.2f} (n={int(c['h2i_n'])}, still holding at block end: {int(c['h2i_censored'])})"))
    r.append(("final load as % of true e1RM / of the ideal for the prescription", f"{pct(div(c['final_ratio'], c['final_n']))} / {pct(div(c['final_vs_ideal'], c['final_n']))}"))
    r.append(("4.4 start: load vs ideal, mean", pct(div(c["start_vs_ideal"], c["start_n"]))))
    r.append(("4.4 start: load as % of true e1RM (ideal would be)", f"{pct(div(c['start_e1_ratio'], c['start_n']))} ({pct(div(c['start_ideal_ratio'], c['start_n']))})"))
    r.append(("4.4 start above what the lifter could do for repMin", pct(div(c["start_fp"], c["start_n"]))))
    return r

def main():
    paths = [p for a in sys.argv[1:] for p in glob.glob(a)]
    cells, lifters, failed, secs = load(paths)
    out = ["# Lifter simulation", ""]
    out.append(f"{sum(lifters.values())} lifter-blocks, {secs/3600:.1f} CPU-hours. Failures: {dict(failed) or 'none'}.")
    out.append("")
    for p in PROFILES:
        for v in VARIANTS:
            out.append(f"## {p} / {v}")
            out.append("")
            per = {}
            for t, label in TEMPLATES:
                k = (t, p, v)
                per[t] = rows(cells[k], lifters[k]) if k in cells else None
            out.append("| metric | " + " | ".join(l for _, l in TEMPLATES) + " |")
            out.append("|---|" + "---|" * len(TEMPLATES))
            names = [n for n, _ in next(r for r in per.values() if r)] if any(per.values()) else []
            for i, name in enumerate(names):
                out.append(f"| {name} | " + " | ".join((per[t][i][1] if per[t] else "-") for t, _ in TEMPLATES) + " |")
            out.append("")
    # compact comparison: each variant against shipped, per profile (both templates pooled)
    out.append("## Variants against shipped (templates pooled)")
    out.append("")
    out.append("| profile | variant | false positive | tracking error | increase | hold (RIR adj) | hold (reps short) | valve | hold to increase | final % ideal | 4.4 start vs ideal |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for p in PROFILES:
        for v in VARIANTS:
            c = collections.defaultdict(float); n = 0
            for t, _ in TEMPLATES:
                k = (t, p, v)
                if k not in cells: continue
                for key, val in cells[k].items(): c[key] += val
                n += lifters[k]
            if not n: continue
            d = c["decisions"]
            out.append(f"| {p} | {v} | {pct(div(c['fp_n'], c['track_n']))} | {pct(div(c['track_sum'], c['track_n']))} | {pct(div(c['increases'], d))} | "
                       f"{pct(div(c['hold_rirAdj'], d))} | {pct(div(c['hold_repsShort'], d))} | {div(c['valve'], n):.2f}/block | {div(c['h2i_sum'], c['h2i_n']):.2f} | "
                       f"{pct(div(c['final_vs_ideal'], c['final_n']))} | {pct(div(c['start_vs_ideal'], c['start_n']))} |")
    print("\n".join(out))

if __name__ == "__main__":
    main()
