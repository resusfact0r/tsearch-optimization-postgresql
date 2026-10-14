#!/bin/bash
# cg_sql.sh NAME  < query.sql
#
# Runs the SQL from stdin in a single-user backend under callgrind and writes
# $CG_OUT/NAME.out.  Env as in cg_run.sh: CG_PGDATA (required), CG_OUT, CG_DBG.
# Extra valgrind options can be passed via CG_VGOPTS (e.g. --cache-sim=yes).
set -e
: "${CG_PGDATA:?set CG_PGDATA}"
CG_OUT=${CG_OUT:-.}
valgrind --tool=callgrind ${CG_DBG:+--extra-debuginfo-path=$CG_DBG} $CG_VGOPTS \
    --callgrind-out-file=$CG_OUT/$1.out --dump-instr=no \
    /usr/lib/postgresql/14/bin/postgres --single -D "$CG_PGDATA" \
    -c jit=off -c max_parallel_workers_per_gather=0 bench > $CG_OUT/$1.stdout 2> $CG_OUT/$1.vg
