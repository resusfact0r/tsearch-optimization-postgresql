#!/bin/bash
# stage22_callgrind.sh
#
# Stage 2.2: cost of TOAST inside function calls, and how many times a vector
# is fetched from TOAST per row in a typical top-k query.
# Needs the private cluster (stopped) with tables from sql/uid/21_toast_tables.sql.
# Env: CG_PGDATA, CG_OUT, CG_DBG (see cg_run.sh).  --only-b: skip part A.
#
# Part A: per-call cost of @@ / ts_rank / ts_rank_cd on TOAST-enabled tables
#         n_* (vector alone) and b_* (body + vector), and2 queries.
# Part B: SELECT id, ts_rank(col,q) FROM b_* WHERE col @@ q ORDER BY 2 DESC LIMIT 10
#         with seqscan and (tsvector only) GIN bitmap scan; 5 queries per type.
set -e
TOOLS="$(cd "$(dirname "$0")" && pwd)"
: "${CG_PGDATA:?}"; : "${CG_OUT:?}"; mkdir -p "$CG_OUT"

qcol() { case $1 in tsv) echo q_orig;; tsv_int) echo q_int;; uidv) echo q_uid;; esac; }

if [ "$1" != "--only-b" ]; then
# ---- Part A
for layout in n b; do for v in tsv tsv_int uidv; do for fn in match ts_rank ts_rank_cd; do
    qc=$(qcol $v); nq=5; [ $fn = ts_rank_cd ] && nq=2
    case $fn in
        match)      e="count(*) FILTER (WHERE col @@ x.q)";;
        ts_rank)    e="sum(ts_rank(col, x.q))";;
        ts_rank_cd) e="sum(ts_rank_cd(col, x.q))";;
    esac
    echo "SELECT $e FROM (SELECT $qc AS q FROM q WHERE qtype='and2' ORDER BY qid LIMIT $nq) x CROSS JOIN ${layout}_$v" \
        | "$TOOLS/cg_sql.sh" "A.$layout.$v.$fn"
    echo "A $layout $v $fn done"
done; done; done
fi

# ---- Part B
# --separate-callers=3 keeps the call context (detoast_attr'pg_detoast_datum'uid_rank_tt),
# so TOAST fetches can be attributed to @@ or ts_rank
export CG_VGOPTS="--separate-callers=3"
for qt in single and2 phrase; do for v in tsv tsv_int uidv; do for scan in seq gin; do
    [ $v = uidv ] && [ $scan = gin ] && continue
    qc=$(qcol $v)
    if [ $scan = seq ]; then set_scan="SET enable_bitmapscan = off"; else set_scan="SET enable_seqscan = off"; fi
    {
        echo "$set_scan"
        echo "SET enable_indexscan = off"
        echo "SELECT count(*), sum(r) FROM (SELECT x.qid FROM q x WHERE x.qtype='$qt' ORDER BY x.qid LIMIT 5) qq CROSS JOIN LATERAL (SELECT id, ts_rank(t.col, x.$qc) AS r FROM q x, b_$v t WHERE x.qid = qq.qid AND t.col @@ x.$qc ORDER BY 2 DESC LIMIT 10) top"
    } | "$TOOLS/cg_sql.sh" "B.$qt.$v.$scan"
    echo "B $qt $v $scan done"
done; done; done
echo ALLDONE
