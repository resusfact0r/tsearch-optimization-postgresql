#!/usr/bin/env python3
"""
stage22_report.py CG_OUT   -- tables for stage 2.2 from tools/stage22_callgrind.sh profiles.
"""
import os, subprocess, sys

D = sys.argv[1]
TOOLS = os.path.dirname(os.path.abspath(__file__))
ENTRY = {
    ("tsv", "match"): "ts_match_vq", ("tsv_int", "match"): "ts_match_vq", ("uidv", "match"): "uidvector_match_vq",
    ("tsv", "ts_rank"): "ts_rank_tt", ("tsv_int", "ts_rank"): "ts_rank_tt", ("uidv", "ts_rank"): "uid_rank_tt",
    ("tsv", "ts_rank_cd"): "ts_rankcd_tt", ("tsv_int", "ts_rank_cd"): "ts_rankcd_tt", ("uidv", "ts_rank_cd"): "uid_rankcd_tt",
}
VNAME = {"tsv": "tsvector", "tsv_int": "прокси", "uidv": "uidvector"}

def n(x):
    """number with thin-space thousands separator"""
    return f"{x:,.0f}".replace(",", " ")


def stats(name, funcs):
    path = os.path.join(D, name + ".out")
    out = subprocess.run([sys.executable, os.path.join(TOOLS, "cg_calls.py"), path] + funcs,
                         capture_output=True, text=True, check=True).stdout
    res = {}
    for line in out.splitlines():
        f, c, i, _ = line.split("\t")
        res[f] = (int(c), int(i))
    total = 0
    with open(path) as fh:
        for line in fh:
            if line.startswith(("summary:", "totals:")):
                total = int(line.split()[1])
    return res, total

print("## A. Один вызов функции на таблице с TOAST (запросы and2), инструкций на вызов\n")
print("| Раскладка | Функция | Вариант | вынесено в TOAST, % вызовов | одно чтение из TOAST | **TOAST на вызов** | **вычисление** | **всего** | доля TOAST | x к tsvector (всего) |")
print("|---|---|---|---|---|---|---|---|---|---|")
for layout, lname in (("n", "(id, вектор)"), ("b", "(id, body, вектор)")):
    for fn in ("match", "ts_rank", "ts_rank_cd"):
        base_total = None
        for v in ("tsv", "tsv_int", "uidv"):
            e = ENTRY[(v, fn)]
            r, _ = stats(f"A.{layout}.{v}.{fn}", [e, "detoast_attr"])
            calls, incl = r[e]
            dcalls, dincl = r["detoast_attr"]
            toast = dincl / calls
            total = incl / calls
            comp = total - toast
            base_total = base_total or total
            fetch = dincl / dcalls if dcalls else 0
            fnl = {"match": "`@@`", "ts_rank": "`ts_rank`", "ts_rank_cd": "`ts_rank_cd`"}[fn]
            print(f"| {lname} | {fnl} | {VNAME[v]} | {100*dcalls/calls:.1f} | {n(fetch)} | {n(toast)} | {n(comp)} | {n(total)} | {100*toast/total:.0f}% | {base_total/total:.2f} |")

def ctx_calls(name, func):
    """{context_name: (calls, incl)} for all call contexts of func"""
    path = os.path.join(D, name + ".out")
    out = subprocess.run([sys.executable, os.path.join(TOOLS, "cg_calls.py"), path, "--ctx", func],
                         capture_output=True, text=True, check=True).stdout
    res = {}
    for line in out.splitlines():
        k, c, i, _ = line.split("\t")
        res[k] = (int(c), int(i))
    return res

print("\n## B. Топ-10: WHERE col @@ q ORDER BY ts_rank(col, q) DESC LIMIT 10, таблица (id, body, вектор), 5 запросов\n")
print("| Запросы | Вариант | План | вызовов `@@` | вызовов `ts_rank` | чтений TOAST из `@@` | чтений TOAST из `ts_rank` | доля инструкций на TOAST | всего инструкций, млн |")
print("|---|---|---|---|---|---|---|---|---|")
for qt in ("single", "and2", "phrase"):
    for v in ("tsv", "tsv_int", "uidv"):
        for scan in ("seq", "gin"):
            name = f"B.{qt}.{v}.{scan}"
            if not os.path.exists(os.path.join(D, name + ".out")):
                continue
            m, rk = ENTRY[(v, "match")], ENTRY[(v, "ts_rank")]
            r, total = stats(name, [m, rk, "detoast_attr"])
            mc, rc = r[m][0], r[rk][0]
            di = r["detoast_attr"][1]
            from_m = from_r = 0
            for k, (c, _) in ctx_calls(name, "detoast_attr").items():
                if m in k:
                    from_m += c
                elif rk in k:
                    from_r += c
            plan = "seq scan" if scan == "seq" else "GIN bitmap"
            print(f"| {qt} | {VNAME[v]} | {plan} | {n(mc)} | {n(rc)} | {n(from_m)} | {n(from_r)} | {100*di/total:.0f}% | {n(total/1e6)} |")
