-- 12_uid_verify.sql
-- uidvector/uidquery must give the same answers as tsvector/tsquery.
-- Benchmark results are meaningless if anything here fails.

\timing on
\echo '=== uid verification ==='

-- 1. Row coverage and lexeme counts per document (full corpus)
SELECT count(*)                                         AS docs,
       count(u.uidv)                                    AS docs_with_uidv,
       count(*) FILTER (WHERE length(d.tsv) <> length(u.uidv)) AS lexcount_mismatch
FROM docs d LEFT JOIN docs_uid u USING (id);
-- Expected: docs = docs_with_uidv, lexcount_mismatch = 0

-- 2. Every benchmark query converted, no unknown lexemes (id 0)
SELECT count(*) AS queries,
       count(*) FILTER (WHERE q_uid IS NULL OR 0 = ANY (uid_lexids(q_uid))) AS bad_queries
FROM bench_queries;

-- 3. Verification sample: 5000 docs x all 900 queries
DROP TABLE IF EXISTS verify_sample;
CREATE TABLE verify_sample AS
SELECT d.id, d.tsv, u.uidv
FROM docs d JOIN docs_uid u USING (id)
WHERE d.id % 100 = 0;

\echo '@@ and rank equivalence on the sample (all bench queries):'
SELECT b.qtype,
       count(*)                                                       AS pairs,
       count(*) FILTER (WHERE s.tsv @@ b.q_orig)                      AS matched,
       count(*) FILTER (WHERE (s.tsv @@ b.q_orig) <> (s.uidv @@ b.q_uid)) AS match_mismatch,
       count(*) FILTER (WHERE ts_rank(s.tsv, b.q_orig) <> ts_rank(s.uidv, b.q_uid))       AS rank_not_bitexact,
       max(abs(ts_rank(s.tsv, b.q_orig) - ts_rank(s.uidv, b.q_uid))
           / greatest(ts_rank(s.tsv, b.q_orig), 1e-20))                AS rank_max_reldiff,
       count(*) FILTER (WHERE ts_rank_cd(s.tsv, b.q_orig) <> ts_rank_cd(s.uidv, b.q_uid)) AS rank_cd_not_bitexact,
       max(abs(ts_rank_cd(s.tsv, b.q_orig) - ts_rank_cd(s.uidv, b.q_uid))
           / greatest(ts_rank_cd(s.tsv, b.q_orig), 1e-20))             AS rank_cd_max_reldiff
FROM verify_sample s CROSS JOIN bench_queries b
GROUP BY b.qtype ORDER BY b.qtype;
-- Expected: match_mismatch = 0; reldiff ~1e-7 at most (float summation
-- order differs: operands are sorted by id instead of by string)

-- 4. Full-corpus hit counts for a few queries of each type
SELECT b.qid, b.qtype, b.q_orig::text, b.q_uid::text,
       (SELECT count(*) FROM docs     WHERE tsv  @@ b.q_orig) AS n_tsv,
       (SELECT count(*) FROM docs_uid WHERE uidv @@ b.q_uid)  AS n_uid
FROM bench_queries b
WHERE b.qid IN (1, 250, 500, 501, 600, 700, 701, 800, 900)
ORDER BY b.qid;
-- Expected: n_tsv = n_uid

DROP TABLE verify_sample;
\timing off
\echo '12_uid_verify.sql: done'
