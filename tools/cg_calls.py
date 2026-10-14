#!/usr/bin/env python3
"""
cg_calls.py FILE.out [--ctx] FUNC [FUNC ...]

For each FUNC: number of calls and inclusive Ir (cost of the calls including
callees), summed over all call sites in a callgrind profile.  Works directly
on the callgrind file format (fn=/cfn=/calls= records), so call counts are
exact.  Prints: func calls incl_Ir incl_Ir_per_call

Profiles made with --separate-callers=N name functions with their call
context, e.g. detoast_attr'pg_detoast_datum'uid_rank_tt; FUNC matches all
contexts.  With --ctx each context is printed on its own line.
"""
import re, sys

path = sys.argv[1]
by_ctx = "--ctx" in sys.argv
funcs = [a for a in sys.argv[2:] if a != "--ctx"]
names = {}          # "(id)" -> name, from name compression
calls = {}
incl = {}
cur_cfn = None
pending_calls = None

def resolve(spec):
    m = re.match(r"(\(\d+\))(?:\s+(.*))?", spec)
    if not m:
        return spec.strip()
    if m.group(2):
        names[m.group(1)] = m.group(2).strip()
    return names.get(m.group(1), m.group(1))

with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("fn="):
            resolve(line[3:]); cur_cfn = None
        elif line.startswith("cfn="):
            cur_cfn = resolve(line[4:])
        elif line.startswith("calls="):
            pending_calls = int(line[6:].split()[0])
        elif pending_calls is not None and line and (line[0].isdigit() or line[0] in "+-*"):
            parts = line.split()
            ir = int(parts[1]) if len(parts) > 1 else 0
            calls[cur_cfn] = calls.get(cur_cfn, 0) + pending_calls
            incl[cur_cfn] = incl.get(cur_cfn, 0) + ir
            pending_calls = None

for fn in funcs:
    # exact symbol, LTO-suffixed variants (name.lto_priv.N), call contexts (name'caller)
    keys = [k for k in calls if k == fn or k.startswith(fn + ".") or k.startswith(fn + "'")]
    if by_ctx:
        for k in sorted(keys):
            print(f"{k}\t{calls[k]}\t{incl[k]}\t{incl[k] / calls[k] if calls[k] else 0:.0f}")
        continue
    c = sum(calls[k] for k in keys); i = sum(incl[k] for k in keys)
    print(f"{fn}\t{c}\t{i}\t{(i / c if c else 0):.0f}")
