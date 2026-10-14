-- 22_topk_time.sql
-- Stage 2.2 (private cluster, DB bench): wall time of the top-10 query
--   SELECT id, ts_rank(col, q) FROM b_<variant> WHERE col @@ q ORDER BY 2 DESC LIMIT 10
-- for 5 queries of each type; seq scan vs GIN bitmap scan (tsvector only).
-- reps repetitions, median of the total over 5 queries, ms.

\if :{?reps} \else \set reps 7 \endif
SET jit = off;
SET max_parallel_workers_per_gather = 0;

DROP TABLE IF EXISTS topk_res;
CREATE TABLE topk_res (qtype text, variant text, scan text, rep int, ms float8);

CREATE OR REPLACE FUNCTION topk_one(p_qt text, p_v text, p_scan text, p_rep int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    qcol text := CASE p_v WHEN 'tsv' THEN 'q_orig' WHEN 'tsv_int' THEN 'q_int' ELSE 'q_uid' END;
    qtyp text := CASE p_v WHEN 'uidv' THEN 'uidquery' ELSE 'tsquery' END;
    qtext text; t0 timestamptz; total float8 := 0; dummy bigint;
BEGIN
    IF p_scan = 'seq' THEN
        SET LOCAL enable_bitmapscan = off; SET LOCAL enable_seqscan = on;
    ELSE
        SET LOCAL enable_bitmapscan = on;  SET LOCAL enable_seqscan = off;
    END IF;
    SET LOCAL enable_indexscan = off;
    FOR qtext IN EXECUTE format('SELECT %I::text FROM q WHERE qtype = %L ORDER BY qid LIMIT 5', qcol, p_qt) LOOP
        t0 := clock_timestamp();
        EXECUTE format('SELECT count(*) FROM (SELECT id, ts_rank(col, %L::%s) r FROM %I
                        WHERE col @@ %L::%s ORDER BY 2 DESC LIMIT 10) t',
                       qtext, qtyp, 'b_' || p_v, qtext, qtyp) INTO dummy;
        total := total + extract(epoch FROM clock_timestamp() - t0) * 1000;
    END LOOP;
    INSERT INTO topk_res VALUES (p_qt, p_v, p_scan, p_rep, total);
END $$;

-- warm-up
SELECT topk_one('single', v, 'seq', 0) FROM unnest(ARRAY['tsv','tsv_int','uidv']) v;
TRUNCATE topk_res;

SELECT topk_one(qt, v, sc, r)
FROM generate_series(1, :reps) r,
     unnest(ARRAY['single','and2','phrase']) qt,
     unnest(ARRAY['tsv','tsv_int','uidv']) v,
     unnest(ARRAY['seq','gin']) sc
WHERE NOT (v = 'uidv' AND sc = 'gin')
ORDER BY r, qt, sc, v;

SELECT qtype, scan,
       round(max(m) FILTER (WHERE variant='tsv')::numeric, 2)     AS tsv_ms,
       round(max(m) FILTER (WHERE variant='tsv_int')::numeric, 2) AS proxy_ms,
       round(max(m) FILTER (WHERE variant='uidv')::numeric, 2)    AS uidv_ms,
       round((max(m) FILTER (WHERE variant='tsv') / max(m) FILTER (WHERE variant='uidv'))::numeric, 2) AS x_uidv,
       round(max(spread)::numeric, 2) AS worst_spread
FROM (SELECT qtype, variant, scan, percentile_cont(0.5) WITHIN GROUP (ORDER BY ms) m,
             max(ms)/min(ms) spread
      FROM topk_res GROUP BY 1,2,3) s
GROUP BY 1, 2
ORDER BY array_position(ARRAY['single','and2','phrase'], qtype), scan DESC;
