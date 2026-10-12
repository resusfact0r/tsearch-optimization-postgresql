-- 11_uid_load.sql
-- Materializes uidvector for the whole corpus (separate table, so that the
-- big docs table is not rewritten) and uidquery for the benchmark workload.

\timing on

DROP TABLE IF EXISTS docs_uid;
CREATE TABLE docs_uid AS
SELECT id, tsv_to_uidv(tsv) AS uidv
FROM docs;
ALTER TABLE docs_uid ADD PRIMARY KEY (id);
ALTER TABLE docs_uid SET (autovacuum_enabled = false, toast.autovacuum_enabled = false);
VACUUM ANALYZE docs_uid;

ALTER TABLE bench_queries ADD COLUMN IF NOT EXISTS q_uid uidquery;
UPDATE bench_queries SET q_uid = tsq_to_uidq(q_orig);

\echo ''
\echo '=== uidvector sizes (vs tsvector baseline and base36 proxy) ==='
SELECT
    pg_size_pretty(sum(pg_column_size(d.tsv)))       AS tsv,
    pg_size_pretty(sum(pg_column_size(d.tsv_int)))   AS tsv_int_proxy,
    pg_size_pretty(sum(pg_column_size(u.uidv)))      AS uidv,
    round(100.0 * sum(pg_column_size(u.uidv)) / sum(pg_column_size(d.tsv)), 1) AS uidv_pct_of_tsv
FROM docs d JOIN docs_uid u USING (id);

SELECT pg_size_pretty(pg_table_size('docs_uid')) AS docs_uid_table_incl_toast;

\timing off
\echo '11_uid_load.sql: done'
