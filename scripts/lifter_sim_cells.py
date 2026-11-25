#!/usr/bin/env python3
"""Cell comparison for the sensitivity sweeps and the valve grid.
   scripts/lifter_sim_cells.py [--weekly] name=glob [name=glob ...]
   One block per profile: rows = cell x variant. Columns: false positive, increase, holds (RIR adj / reps short), valve releases per block,
   sessions hold->increase, final load as % of the ideal and of the true e1RM. --weekly: planned load as % of ideal by week, shipped, per profile."""
import json, sys, glob, collections

def agg(paths):
    cells = collections.defaultdict(lambda: collections.defaultdict(float)); n = collections.Counter(); wk = collections.defaultdict(lambda: ([0]*13, [0.0]*13))
    for p in paths:
        for line in open(p):
            if not line.strip(): continue
            d = json.loads(line); a = d["acc"]; k = (d["profile"], d["variant"]); n[k] += 1; c = cells[k]
            for f in "track_n track_sum fp_n decisions increases holds hold_rirAdj hold_repsShort valve h2i_n h2i_sum h2i_censored final_n final_ratio final_vs_ideal".split(): c[f] += a.get(f, 0)
            for i in range(13):
                wk[k][0][i] += a.get("w_n", [0]*13)[i]; wk[k][1][i] += a.get("w_sum", [0.0]*13)[i]
    return cells, n, wk

def pct(x): return "n/a" if x != x else f"{100*x:.1f}%"
def div(a, b): return a / b if b else float("nan")

def main():
    args = sys.argv[1:]; weekly = "--weekly" in args; args = [a for a in args if a != "--weekly"]
    data = {}
    for a in args:
        name, g = a.split("=", 1); data[name] = agg(glob.glob(g))
    profiles = sorted({k[0] for d in data.values() for k in d[0]}, key=lambda p: ["accurate", "typical", "all-zero", "effort-off"].index(p))
    variants = ["shipped", "valve-total", "repeat-top2", "top2-lifter", "count-first3", "rir-tol1"]
    if weekly:
        print("| profile | " + " | ".join(f"wk{i+1}" for i in range(13)) + " |\n|---|" + "---|" * 13)
        for p in profiles:
            for name, (cells, n, wk) in data.items():
                for v in variants:
                    if (p, v) not in wk: continue
                    ns, ss = wk[(p, v)]
                    print(f"| {p} / {v} ({name}) | " + " | ".join(pct(1 + div(ss[i], ns[i])) if ns[i] else "–" for i in range(13)) + " |")
        return
    for p in profiles:
        print(f"\n### {p}\n\n| cell | variant | blocks | false positive | increase | hold: RIR adj | hold: reps short | valve/block | hold->increase | final % ideal | final % true e1RM |\n|---|---|---|---|---|---|---|---|---|---|---|")
        for name, (cells, n, wk) in data.items():
            for v in variants:
                k = (p, v)
                if k not in cells: continue
                c = cells[k]; d = c["decisions"]
                # final % of true e1RM: final_ratio is the mean ratio summed over final_n
                print(f"| {name} | {v} | {n[k]} | {pct(div(c['fp_n'], c['track_n']))} | {pct(div(c['increases'], d))} | {pct(div(c['hold_rirAdj'], d))} | {pct(div(c['hold_repsShort'], d))} | "
                      f"{div(c['valve'], n[k]):.2f} | {div(c['h2i_sum'], c['h2i_n']):.2f} (n={int(c['h2i_n'])}, open {int(c['h2i_censored'])}) | {pct(div(c['final_vs_ideal'], c['final_n']))} | {pct(div(c['final_ratio'], c['final_n']))} |")
main()
