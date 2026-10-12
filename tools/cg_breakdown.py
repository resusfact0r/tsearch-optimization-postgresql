#!/usr/bin/env python3
"""
cg_breakdown.py DIR [--top]

Reads callgrind profiles DIR/cg.<variant>.<fn>.<qtype>.out produced by
tools/cg_run.sh and prints instructions (Ir) per function call, split by
category.  The profile of fn='base' (sum(length(col))) of the same variant
and query type is subtracted function by function, so scan/executor cost
cancels out and only the cost of the measured function remains.
"""
import re, subprocess, sys, glob, os
from collections import defaultdict

DIR = sys.argv[1]
NROWS = 20000          # rows in table s


def ncalls(out_path):
    """number of function calls = queries (from .nq sidecar) x rows"""
    nq_file = out_path[:-len(".out")] + ".nq"
    nq = int(open(nq_file).read()) if os.path.exists(nq_file) else 20
    return nq * NROWS

CATS = [
    ("str_compare",  r"^(tsCompareString|__memcmp\w*|memcmp)$"),
    ("lex_lookup",   r"^(find_wordentry|checkcondition_str|checkclass_str|uidv_find|checkcondition_uid)$"),
    ("ts_execute",   r"^(TS_execute\w*|TS_phrase\w*|checkcondition_QueryOperand|fillQueryRepresentationData|resetQueryRepresentation)$"),
    ("memset",       r"^__memset\w*$"),
    ("alloc_free",   r"^(palloc\w*|pfree|repalloc|AllocSet\w*|MemoryContext\w*|__memcpy\w*|__memmove\w*)$"),
    ("sort",         r"^(pg_qsort|qsort_arg|qsort|msort\w*|compareQueryOperand|compareDocR|SortAndUniqItems|med3|swapfunc)$"),
    ("rank_logic",   r"^(calc_rank\w*|word_distance|cnt_length|uidv_cnt_length|get_docrep|Cover|__ieee754\w*|__exp\w*|exp|__log\w*|log|sqrt\w*|getWeights)$"),
    ("fn_entry",     r"^(ts_rank\w*|ts_rankcd\w*|ts_match_vq|uid_rank\w*|uid_rankcd\w*|uidvector_match\w*|uid_match)$"),
]

def excl(path):
    out = subprocess.run(["callgrind_annotate", "--threshold=100", path],
                         capture_output=True, text=True).stdout
    res = defaultdict(int)
    for line in out.splitlines():
        m = re.match(r"\s*([\d,]+)\s+\([^)]*\)\s+(\S+?):(\S+)\s+\[", line)
        if not m or m.group(3) == "PROGRAM":
            continue
        res[m.group(3)] += int(m.group(1).replace(",", ""))
    return res

def cat_of(fn):
    for c, rx in CATS:
        if re.match(rx, fn):
            return c
    return "other"

profiles = {}
for p in glob.glob(os.path.join(DIR, "cg.*.out")):
    _, v, fn, qt, _ = os.path.basename(p).split(".")
    prof = excl(p)
    n = ncalls(p)
    # normalize to Ir per call right away: base and fn may differ in nq
    profiles[(v, fn, qt)] = {f: c / n for f, c in prof.items()}

cats = [c for c, _ in CATS] + ["other"]
rows = []
for (v, fn, qt), prof in sorted(profiles.items()):
    if fn == "base" or (v, "base", qt) not in profiles:
        continue
    base = profiles[(v, "base", qt)]
    by = defaultdict(float)
    for f in set(prof) | set(base):
        by[cat_of(f)] += prof.get(f, 0) - base.get(f, 0)
    rows.append((fn, qt, v, sum(by.values()), by))

order_fn = {"match": 0, "ts_rank": 1, "ts_rank_cd": 2}
order_qt = {"single": 0, "and2": 1, "phrase": 2}
order_v = {"tsv": 0, "tsv_int": 1, "uidv": 2}
rows.sort(key=lambda r: (order_fn[r[0]], order_qt[r[1]], order_v[r[2]]))

print("Instructions (Ir) per call, net of scan (base subtracted)\n")
hdr = f"{'fn':<11}{'qtype':<8}{'variant':<9}{'total':>7}{'x_vs_tsv':>9}" + "".join(f"{c:>12}" for c in cats)
print(hdr); print("-" * len(hdr))
tsv_total = {(r[0], r[1]): r[3] for r in rows if r[2] == "tsv"}
for fn, qt, v, tot, by in rows:
    x = tsv_total[(fn, qt)] / tot if tot else 0
    print(f"{fn:<11}{qt:<8}{v:<9}{tot:>7.0f}{x:>9.2f}" + "".join(f"{by[c]:>12.0f}" for c in cats))

if "--top" in sys.argv:
    for (v, fn, qt), prof in sorted(profiles.items()):
        if fn == "base": continue
        base = profiles[(v, "base", qt)]
        d = sorted((prof.get(f, 0) - base.get(f, 0), f) for f in set(prof) | set(base))
        print(f"\n{v} {fn} {qt}: top functions, Ir/call")
        for val, f in reversed(d[-8:]):
            print(f"  {val:8.0f}  {f}")
