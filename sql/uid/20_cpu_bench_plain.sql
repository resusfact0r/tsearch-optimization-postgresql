-- 20_cpu_bench_plain.sql
-- Pure CPU cost of @@ / ts_rank / ts_rank_cd without TOAST effects.
-- Runs in a separate DB where table s(id, tsv, tsv_int, uidv) has all three
-- columns with STORAGE PLAIN (inline, uncompressed): detoasting is a no-op,
-- so the only difference between variants is the function itself.
-- q(qid, qtype, q_orig, q_int, q_uid): 20 queries per type.
--
-- One measurement = SELECT sum(fn(col, query)) FROM s for each of the 20
-- queries of a type; 'base' = sum(length(col)) (scan + executor overhead).
-- reps repetitions, variants interleaved; median reported.

\if :{?reps} \else \set reps 7 \endif
SET jit = off;
SET max_parallel_workers_per_gather = 0;

DROP TABLE IF EXISTS cpu_res;
CREATE TABLE cpu_res (variant text, fn text, qtype text, rep int, ms float8, ncalls bigint);

CREATE OR REPLACE FUNCTION cpu_one(p_variant text, p_fn text, p_qtype text, p_rep int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    qcol  text := CASE p_variant WHEN 'tsv' THEN 'q_orig' WHEN 'tsv_int' THEN 'q_int' ELSE 'q_uid' END;
    qtyp  text := CASE p_variant WHEN 'uidv' THEN 'uidquery' ELSE 'tsquery' END;
    qtext text; expr text; t0 timestamptz; total float8 := 0; n bigint := 0; x float8;
BEGIN
    FOR qtext IN EXECUTE format('SELECT %I::text FROM q WHERE qtype = %L ORDER BY qid', qcol, p_qtype) LOOP
        expr := CASE p_fn
            WHEN 'base'       THEN format('sum(length(%I))', p_variant)
            WHEN 'match'      THEN format('count(*) FILTER (WHERE %I @@ %L::%s)', p_variant, qtext, qtyp)
            WHEN 'ts_rank'    THEN format('sum(ts_rank(%I, %L::%s))', p_variant, qtext, qtyp)
            WHEN 'ts_rank_cd' THEN format('sum(ts_rank_cd(%I, %L::%s))', p_variant, qtext, qtyp)
        END;
        t0 := clock_timestamp();
        EXECUTE format('SELECT (%s)::float8 FROM s', expr) INTO x;
        total := total + extract(epoch FROM clock_timestamp() - t0) * 1000;
        n := n + (SELECT count(*) FROM s);
    END LOOP;
    INSERT INTO cpu_res VALUES (p_variant, p_fn, p_qtype, p_rep, total, n);
END $$;

SELECT cpu_one(v, 'base', 'single', 0) FROM unnest(ARRAY['tsv','tsv_int','uidv']) v;  -- warm-up
TRUNCATE cpu_res;

SELECT cpu_one(v, f, qt, r)
FROM generate_series(1, :reps) r,
     unnest(ARRAY['single','and2','phrase']) qt,
     unnest(ARRAY['base','match','ts_rank','ts_rank_cd']) f,
     unnest(ARRAY['tsv','tsv_int','uidv']) v
ORDER BY r, qt, f, v;

\echo '=== ns per call, net of scan overhead (median of reps) ==='
WITH med AS (
    SELECT variant, fn, qtype, percentile_cont(0.5) WITHIN GROUP (ORDER BY ms) ms,
           max(ms)/min(ms) spread, max(ncalls) n
    FROM cpu_res GROUP BY 1,2,3
), net AS (
    SELECT m.variant, m.fn, m.qtype, 1e6*(m.ms - b.ms)/m.n AS ns, m.spread
    FROM med m JOIN med b ON b.variant = m.variant AND b.qtype = m.qtype AND b.fn = 'base'
    WHERE m.fn <> 'base'
)
SELECT fn, qtype,
       round(max(ns) FILTER (WHERE variant='tsv')::numeric)     AS tsv_ns,
       round(max(ns) FILTER (WHERE variant='tsv_int')::numeric) AS proxy_ns,
       round(max(ns) FILTER (WHERE variant='uidv')::numeric)    AS uidv_ns,
       round((max(ns) FILTER (WHERE variant='tsv') / max(ns) FILTER (WHERE variant='tsv_int'))::numeric, 2) AS x_proxy,
       round((max(ns) FILTER (WHERE variant='tsv') / max(ns) FILTER (WHERE variant='uidv'))::numeric, 2)    AS x_uidv,
       round(max(spread)::numeric, 2) AS worst_spread
FROM net GROUP BY 1,2
ORDER BY array_position(ARRAY['match','ts_rank','ts_rank_cd'], fn),
         array_position(ARRAY['single','and2','phrase'], qtype);

\echo '=== scan overhead (base), ns per row ==='
SELECT variant, qtype, round((1e6*percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)/max(ncalls))::numeric) ns
FROM cpu_res WHERE fn='base' GROUP BY 1,2 ORDER BY 2,1;
