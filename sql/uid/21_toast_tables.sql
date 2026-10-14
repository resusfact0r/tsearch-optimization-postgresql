-- 21_toast_tables.sql
-- Stage 2.2 (private cluster, DB bench): the same 20K vectors stored the
-- normal way (STORAGE EXTENDED, TOAST allowed), in two layouts:
--   n_<variant>(id, col)        narrow: vector alone in the row
--   b_<variant>(id, body, col)  realistic: document text in the same row
-- <variant> = tsv | tsv_int | uidv.  Source: s (PLAIN copy) + bodies.
-- GIN indexes on the tsvector tables for the top-k query scenario.

\set ON_ERROR_STOP 1
DROP TABLE IF EXISTS n_tsv, n_tsv_int, n_uidv, b_tsv, b_tsv_int, b_uidv;

CREATE TABLE n_tsv     AS SELECT id, tsv     AS col FROM s;
CREATE TABLE n_tsv_int AS SELECT id, tsv_int AS col FROM s;
CREATE TABLE n_uidv    AS SELECT id, uidv    AS col FROM s;
CREATE TABLE b_tsv     AS SELECT s.id, b.body, s.tsv     AS col FROM s JOIN bodies b USING (id);
CREATE TABLE b_tsv_int AS SELECT s.id, b.body, s.tsv_int AS col FROM s JOIN bodies b USING (id);
CREATE TABLE b_uidv    AS SELECT s.id, b.body, s.uidv    AS col FROM s JOIN bodies b USING (id);

CREATE INDEX b_tsv_gin     ON b_tsv     USING gin (col);
CREATE INDEX b_tsv_int_gin ON b_tsv_int USING gin (col);

VACUUM ANALYZE n_tsv; VACUUM ANALYZE n_tsv_int; VACUUM ANALYZE n_uidv;
VACUUM ANALYZE b_tsv; VACUUM ANALYZE b_tsv_int; VACUUM ANALYZE b_uidv;

-- How the vectors are stored.  A value moved to TOAST has a pointer of
-- 18 bytes in the heap; pg_column_size() reports the real (fetched) size,
-- so out-of-line values are counted via the TOAST table chunk count.
SELECT t AS tbl,
       pg_size_pretty(pg_relation_size(t::regclass))                     AS heap,
       pg_size_pretty(pg_table_size(t::regclass) - pg_relation_size(t::regclass)) AS toast,
       (SELECT reltuples::bigint FROM pg_class WHERE oid = (SELECT reltoastrelid FROM pg_class WHERE oid = t::regclass)) AS toast_chunks
FROM unnest(ARRAY['n_tsv','n_tsv_int','n_uidv','b_tsv','b_tsv_int','b_uidv']) t;
