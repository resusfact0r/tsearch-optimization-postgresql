#!/usr/bin/env bash
# run_uid_experiment.sh
#
# Stage 2 of the FTS uid experiment: real int4 lexeme ids via the uidfts
# C extension (ext/uidfts), compared with tsvector and the base36 proxy.
#
# Requires the stage-1 database (run_experiment.sh): docs, lex_dict,
# bench_queries, tsv_int.
#
# Steps:
#   1. build + load uidfts into fts_bench (no root needed, see ext/uidfts/Makefile)
#   2. 10_uid_crutch.sql  tsvector->uidvector, tsquery->uidquery via lex_dict
#   3. 11_uid_load.sql    docs_uid(id, uidv), bench_queries.q_uid
#   4. 12_uid_verify.sql  equivalence with tsvector
#   5. 13_uid_bench.sql   @@ / ts_rank / ts_rank_cd timings
#   6. 14_uid_report.sql  summary
#
# Usage:
#   ./run_uid_experiment.sh [--skip-load] [--only-bench] [--sample-mod N] [--nq N] [--reps N]

set -euo pipefail

PGUSER="postgres"
DBNAME="fts_bench"
SKIP_LOAD=false
ONLY_BENCH=false
SAMPLE_MOD=25
NQ=20
REPS=5
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql/uid"
RESULTS_DIR="${SCRIPT_DIR}/results/uid"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="${RESULTS_DIR}/uid_experiment_${STAMP}.log"
mkdir -p "${RESULTS_DIR}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-load)  SKIP_LOAD=true ;;
        --only-bench) ONLY_BENCH=true ;;
        --sample-mod) SAMPLE_MOD="$2"; shift ;;
        --nq)         NQ="$2"; shift ;;
        --reps)       REPS="$2"; shift ;;
        -h|--help)    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

PG="psql -U ${PGUSER} -d ${DBNAME} -v ON_ERROR_STOP=1"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "${LOG}"; }
run_sql() {
    log "Running $1 ..."
    local start=$SECONDS
    ${PG} "${@:2}" -f "${SQL_DIR}/$1" 2>&1 | tee -a "${LOG}"
    log "  -> done in $((SECONDS - start))s"
}

if [[ "${ONLY_BENCH}" == "false" ]]; then
    log "Building and loading uidfts..."
    make -C "${SCRIPT_DIR}/ext/uidfts" devload DB="${DBNAME}" PGUSER="${PGUSER}" 2>&1 | tee -a "${LOG}"
    run_sql 10_uid_crutch.sql
    [[ "${SKIP_LOAD}" == "false" ]] && run_sql 11_uid_load.sql
    run_sql 12_uid_verify.sql
fi

run_sql 13_uid_bench.sql -v sample_mod="${SAMPLE_MOD}" -v nq="${NQ}" -v reps="${REPS}"

REPORT="${RESULTS_DIR}/uid_report_${STAMP}.txt"
${PG} -f "${SQL_DIR}/14_uid_report.sql" > "${REPORT}" 2>&1
${PG} -c "\copy uid_bench_results TO '${RESULTS_DIR}/uid_timings_${STAMP}.csv' WITH (FORMAT CSV, HEADER true)"
cat "${REPORT}" | tee -a "${LOG}"
log "=== done. Results in ${RESULTS_DIR}/ ==="
