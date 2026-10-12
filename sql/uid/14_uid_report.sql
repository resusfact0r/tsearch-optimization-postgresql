-- 14_uid_report.sql
-- Summary of 13_uid_bench.sql: medians, net-of-detoast cost, speedups.

\echo ''
\echo '=== Sizes over the full corpus ==='
SELECT
    pg_size_pretty(sum(pg_column_size(d.tsv)))      AS tsv,
    pg_size_pretty(sum(pg_column_size(d.tsv_int)))  AS tsv_int_proxy,
    pg_size_pretty(sum(pg_column_size(u.uidv)))     AS uidv,
    round(avg(pg_column_size(d.tsv)))               AS avg_tsv_b,
    round(avg(pg_column_size(d.tsv_int)))           AS avg_tsv_int_b,
    round(avg(pg_column_size(u.uidv)))              AS avg_uidv_b,
    round(100.0 * sum(pg_column_size(u.uidv)) / sum(pg_column_size(d.tsv)), 1) AS uidv_pct_of_tsv
FROM docs d JOIN docs_uid u USING (id);

\echo ''
\echo '=== Median wall time per run (ms): sum over nq queries x sample rows ==='
WITH med AS (
    SELECT variant, fn, qtype,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY ms) AS ms,
           max(nq) AS nq, max(nrows) AS nrows
    FROM uid_bench_results GROUP BY 1, 2, 3
), det AS (
    SELECT variant, qtype, ms AS det_ms FROM med WHERE fn = 'detoast'
)
SELECT m.fn, m.qtype,
       round(max(m.ms) FILTER (WHERE m.variant = 'tsv')::numeric, 1)     AS tsv_ms,
       round(max(m.ms) FILTER (WHERE m.variant = 'tsv_int')::numeric, 1) AS proxy_ms,
       round(max(m.ms) FILTER (WHERE m.variant = 'uidv')::numeric, 1)    AS uidv_ms,
       round((max(m.ms) FILTER (WHERE m.variant = 'tsv')
            / max(m.ms) FILTER (WHERE m.variant = 'tsv_int'))::numeric, 2) AS x_proxy,
       round((max(m.ms) FILTER (WHERE m.variant = 'tsv')
            / max(m.ms) FILTER (WHERE m.variant = 'uidv'))::numeric, 2)    AS x_uidv,
       -- net of detoast: function CPU cost only
       round((max(m.ms - d.det_ms) FILTER (WHERE m.variant = 'tsv')
            / nullif(max(m.ms - d.det_ms) FILTER (WHERE m.variant = 'tsv_int'), 0))::numeric, 2) AS x_proxy_net,
       round((max(m.ms - d.det_ms) FILTER (WHERE m.variant = 'tsv')
            / nullif(max(m.ms - d.det_ms) FILTER (WHERE m.variant = 'uidv'), 0))::numeric, 2)    AS x_uidv_net,
       round((1e6 * max(m.ms - d.det_ms) FILTER (WHERE m.variant = 'uidv')
            / max(m.nq * m.nrows))::numeric, 0) AS uidv_net_ns_per_call,
       round((1e6 * max(m.ms - d.det_ms) FILTER (WHERE m.variant = 'tsv')
            / max(m.nq * m.nrows))::numeric, 0) AS tsv_net_ns_per_call
FROM med m JOIN det d USING (variant, qtype)
GROUP BY m.fn, m.qtype
ORDER BY array_position(ARRAY['detoast','match','ts_rank','ts_rank_cd'], m.fn),
         array_position(ARRAY['single','and2','phrase'], m.qtype);

\echo ''
\echo '=== Run-to-run spread (max/min of the reps) ==='
SELECT variant, fn, qtype, count(*) AS reps,
       round(min(ms)::numeric, 1) AS min_ms, round(max(ms)::numeric, 1) AS max_ms,
       round((max(ms) / min(ms))::numeric, 2) AS spread
FROM uid_bench_results
GROUP BY 1, 2, 3
ORDER BY spread DESC
LIMIT 8;
