#!/bin/bash
# cg_run.sh VARIANT FN QTYPE NQ
#
# Profiles one workload with callgrind in a single-user backend:
#   SELECT <fn>(col, q) over NQ queries of QTYPE x all rows of table s
# VARIANT: tsv | tsv_int | uidv     FN: base | match | ts_rank | ts_rank_cd
#
# Needs a private cluster (owned by the current user, server stopped) with
# database `bench`, tables s(id, tsv, tsv_int, uidv) and q(qid, qtype,
# q_orig, q_int, q_uid) and uidfts loaded -- see README, "Этап 2.1".
#
# Env:
#   CG_PGDATA  data directory of the private cluster (required)
#   CG_OUT     output dir for cg.<variant>.<fn>.<qtype>.out (default: .)
#   CG_DBG     dir laid out as <dir>/usr/lib/postgresql/14/bin/<debuglink>
#              holding postgres debug symbols (optional, gives names of
#              static functions such as find_wordentry, Cover)
set -e
v=$1; fn=$2; qt=$3; nq=$4
: "${CG_PGDATA:?set CG_PGDATA}"
CG_OUT=${CG_OUT:-.}
case $v in tsv) qc=q_orig;; tsv_int) qc=q_int;; uidv) qc=q_uid;; esac
case $fn in
  base)       e="sum(length($v))";;
  match)      e="count(*) FILTER (WHERE $v @@ x.q)";;
  ts_rank)    e="sum(ts_rank($v, x.q))";;
  ts_rank_cd) e="sum(ts_rank_cd($v, x.q))";;
esac
sql="SELECT $e FROM (SELECT $qc AS q FROM q WHERE qtype='$qt' ORDER BY qid LIMIT $nq) x CROSS JOIN s"
out=$CG_OUT/cg.$v.$fn.$qt
echo "$nq" > $out.nq   # read by cg_breakdown.py
echo "$sql" | valgrind --tool=callgrind ${CG_DBG:+--extra-debuginfo-path=$CG_DBG} \
    --callgrind-out-file=$out.out --dump-instr=no \
    /usr/lib/postgresql/14/bin/postgres --single -D "$CG_PGDATA" \
    -c jit=off -c max_parallel_workers_per_gather=0 bench > $out.stdout 2> $out.vg
