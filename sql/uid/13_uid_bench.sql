-- 13_uid_bench.sql
-- CPU cost of @@ / ts_rank / ts_rank_cd for three representations:
--   tsv     - core tsvector, string lexemes          (q_orig)
--   tsv_int - core tsvector, base36 4-char "ids"     (q_int)   [old proxy]
--   uidv    - uidvector, real int4 ids (uidfts)      (q_uid)
--
-- Method:
--   * a fixed sample of docs (id % :sample_mod = 0) is copied into three
--     separate tables, one per representation, so each scan reads only
--     its own column; everything is warmed up before measuring;
--   * one measurement = run the function over the whole sample for each of
--     the first :nq queries of a query type; total wall time is recorded;
--   * every measurement is repeated :reps times, the median is reported;
--   * 'detoast' = sum(length(col)): the cost of fetching + decompressing
--     the column, which every other function also pays.  net = fn - detoast
--     approximates the pure CPU cost of the function itself.
--
-- Variables (psql -v): sample_mod (default 25 -> 20K docs), nq (20), reps (5)

\if :{?sample_mod} \else \set sample_mod 25 \endif
\if :{?nq}         \else \set nq 20         \endif
\if :{?reps}       \else \set reps 5        \endif

SET jit = off;
SET max_parallel_workers_per_gather = 0;

DROP TABLE IF EXISTS rs_tsv, rs_tsv_int, rs_uidv;
CREATE TABLE rs_tsv     AS SELECT id, tsv     AS col FROM docs     WHERE id % :sample_mod = 0;
CREATE TABLE rs_tsv_int AS SELECT id, tsv_int AS col FROM docs     WHERE id % :sample_mod = 0;
CREATE TABLE rs_uidv    AS SELECT id, uidv    AS col FROM docs_uid WHERE id % :sample_mod = 0;
VACUUM ANALYZE rs_tsv;
VACUUM ANALYZE rs_tsv_int;
VACUUM ANALYZE rs_uidv;

SELECT 'tsv' AS variant, count(*) AS rows, pg_size_pretty(pg_table_size('rs_tsv')) AS table_size,
       round(avg(pg_column_size(col))) AS avg_bytes FROM rs_tsv
UNION ALL
SELECT 'tsv_int', count(*), pg_size_pretty(pg_table_size('rs_tsv_int')),
       round(avg(pg_column_size(col))) FROM rs_tsv_int
UNION ALL
SELECT 'uidv', count(*), pg_size_pretty(pg_table_size('rs_uidv')),
       round(avg(pg_column_size(col))) FROM rs_uidv;

CREATE TABLE IF NOT EXISTS uid_bench_results (
    ts       timestamptz DEFAULT now(),
    variant  text,      -- tsv | tsv_int | uidv
    fn       text,      -- detoast | match | ts_rank | ts_rank_cd
    qtype    text,      -- single | and2 | phrase | -
    rep      int,
    nq       int,
    nrows    bigint,
    ms       float8
);
TRUNCATE uid_bench_results;

-- run `expr` over the sample table for the first nq queries of qtype
CREATE OR REPLACE FUNCTION uid_bench_one(p_variant text, p_fn text, p_qtype text,
                                         p_nq int, p_rep int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    tbl   text := 'rs_' || p_variant;
    qcol  text := CASE p_variant WHEN 'tsv' THEN 'q_orig'
                                 WHEN 'tsv_int' THEN 'q_int'
                                 ELSE 'q_uid' END;
    qtyp  text := CASE p_variant WHEN 'uidv' THEN 'uidquery' ELSE 'tsquery' END;
    qtext text;
    expr  text;
    t0    timestamptz;
    total float8 := 0;
    n     bigint;
    dummy float8;
BEGIN
    FOR qtext IN EXECUTE format(
        -- skip queries whose q_orig was double-stemmed by the old 06 script
        'SELECT %I::text FROM bench_queries WHERE qtype = %L '
        'AND NOT 0 = ANY (uid_lexids(q_uid)) ORDER BY qid LIMIT %s',
        qcol, p_qtype, p_nq)
    LOOP
        expr := CASE p_fn
            WHEN 'match'      THEN format('count(*) FILTER (WHERE col @@ %L::%s)', qtext, qtyp)
            WHEN 'ts_rank'    THEN format('sum(ts_rank(col, %L::%s))', qtext, qtyp)
            WHEN 'ts_rank_cd' THEN format('sum(ts_rank_cd(col, %L::%s))', qtext, qtyp)
            WHEN 'detoast'    THEN 'sum(length(col))'
        END;
        t0 := clock_timestamp();
        EXECUTE format('SELECT (%s)::float8, count(*) FROM %I', expr, tbl) INTO dummy, n;
        total := total + extract(epoch FROM clock_timestamp() - t0) * 1000;
    END LOOP;
    INSERT INTO uid_bench_results(variant, fn, qtype, rep, nq, nrows, ms)
    VALUES (p_variant, p_fn, p_qtype, p_rep, p_nq, n, total);
END;
$$;

\echo 'warm-up...'
SELECT uid_bench_one(v, 'detoast', 'single', 3, 0)
FROM unnest(ARRAY['tsv','tsv_int','uidv']) v;
DELETE FROM uid_bench_results;

\echo 'measuring (this takes a few minutes)...'
-- variants are interleaved inside each repetition to spread drift evenly
SELECT uid_bench_one(v, f, q, :nq, r)
FROM generate_series(1, :reps) r,
     unnest(ARRAY['single','and2','phrase']) q,
     unnest(ARRAY['detoast','match','ts_rank','ts_rank_cd']) f,
     unnest(ARRAY['tsv','tsv_int','uidv']) v
ORDER BY r, q, f, v;

\echo '13_uid_bench.sql: done'
