CREATE EXTENSION uidfts;

-- I/O
SELECT '12:1,5A 3 40:3 12:2'::uidvector;
SELECT '7 5:3 5:3B 5:1'::uidvector;
SELECT ''::uidvector, length('1 2 3:4'::uidvector), uid_lexids('9 1:3 5'::uidvector);
SELECT uidvector('{5,3,5,9}'::int4[], '{4,1,2,3}'::int4[]);
SELECT uidvector('{5,3,5}'::int4[]);
SELECT '12 & (37 | !5) <-> 8:AB'::uidquery, '1 <2> 2 | 3'::uidquery;
SELECT uid_lexids('1 & 2 & 1'::uidquery);
SELECT '1:x'::uidvector;
SELECT 'abc & 1'::uidquery;
SELECT '1:*'::uidquery;

-- @@
SELECT '1:1 2:2 3:5'::uidvector @@ '1 <-> 2'::uidquery,
       '1:1 2:2 3:5'::uidvector @@ '1 <-> 3'::uidquery,
       '1:1 2:2 3:5'::uidvector @@ '2 <3> 3'::uidquery,
       '1:1A 2'::uidvector @@ '1:B'::uidquery,
       '1:1A 2'::uidvector @@ '1:A & !4'::uidquery;

-- Equivalence with core tsvector/tsquery.
-- Lexemes 'a'..'i' map to ids 1..9; string order equals id order, so
-- results must be bit-identical, not just close.
SELECT setseed(0.42);
CREATE TEMP TABLE d AS
SELECT n, string_agg(l || ':' || p || w, ' ') AS txt
FROM generate_series(1, 300) n,
     LATERAL (SELECT chr(97 + (random() * 8)::int) AS l,
                     1 + (random() * 40)::int AS p,
                     (ARRAY['', '', 'A', 'B', 'C'])[1 + (random() * 4)::int] AS w,
                     n AS dummy
              FROM generate_series(1, 1 + (random() * 30)::int)) occ
GROUP BY n;
INSERT INTO d VALUES (0, '');                -- empty document
INSERT INTO d VALUES (-1, 'a b c d');        -- no positions

CREATE TEMP TABLE dv AS
SELECT n, txt::tsvector AS tv,
       translate(txt, 'abcdefghi', '123456789')::uidvector AS uv
FROM d;

CREATE TEMP TABLE q (qs text);
INSERT INTO q VALUES
  ('a'), ('a & b'), ('a | b'), ('a & !b'), ('!a'), ('a <-> b'), ('a <2> b'),
  ('(a | b) <-> c'), ('a:A'), ('a:AB & b'), ('a:C <-> b:A'), ('a <-> b <-> c'),
  ('a & b & c & d'), ('!(a <-> b)'), ('a & a'), ('a | b | c | d | e | f'),
  ('(a & b) | (c <-> d)'), ('a <0> b'), ('i'), ('a & z'), ('!a <-> b');

CREATE TEMP TABLE qv AS
SELECT qs, qs::tsquery AS tq,
       translate(replace(qs, 'z', '0'), 'abcdefghi', '123456789')::uidquery AS uq
FROM q;

-- every query prints the same in both forms (modulo quotes and id mapping)
SELECT count(*) AS query_text_mismatch
FROM qv
WHERE translate(replace(replace(tq::text, '''', ''), 'z', '0'), 'abcdefghi', '123456789') <> uq::text;

SELECT count(*) AS vector_text_mismatch
FROM dv
WHERE translate(replace(tv::text, '''', ''), 'abcdefghi', '123456789') <> uv::text;

SELECT count(*) AS pairs,
       count(*) FILTER (WHERE (tv @@ tq) <> (uv @@ uq)) AS match_mismatch,
       count(*) FILTER (WHERE (tq @@ tv) <> (uq @@ uv)) AS match_qv_mismatch,
       count(*) FILTER (WHERE ts_rank(tv, tq) <> ts_rank(uv, uq)) AS rank_mismatch,
       count(*) FILTER (WHERE ts_rank_cd(tv, tq) <> ts_rank_cd(uv, uq)) AS rank_cd_mismatch,
       count(*) FILTER (WHERE tv @@ tq) AS matched
FROM dv, qv;

-- normalization flags and custom weights
SELECT count(*) FILTER (WHERE ts_rank(tv, tq, m) <> ts_rank(uv, uq, m)) AS rank_norm_mismatch,
       count(*) FILTER (WHERE ts_rank_cd(tv, tq, m) <> ts_rank_cd(uv, uq, m)) AS rank_cd_norm_mismatch,
       count(*) FILTER (WHERE ts_rank('{0.3,0.5,0.7,0.9}', tv, tq, m)
                           <> ts_rank('{0.3,0.5,0.7,0.9}', uv, uq, m)) AS rank_w_mismatch,
       count(*) FILTER (WHERE ts_rank_cd('{0.3,0.5,0.7,0.9}', tv, tq, m)
                           <> ts_rank_cd('{0.3,0.5,0.7,0.9}', uv, uq, m)) AS rank_cd_w_mismatch
FROM dv, qv, generate_series(0, 63) m;

-- pair-of-arrays constructor builds the same vector as text input
SELECT count(*) AS ctor_mismatch
FROM (SELECT n, uv,
             (SELECT uidvector(array_agg(ascii(substr(e, 1, 1)) - 96),
                               array_agg(substring(e from ':(\d+)')::int4))
              FROM regexp_split_to_table(txt, ' ') e
              WHERE txt <> '') AS uv2
      FROM d JOIN dv USING (n)
      WHERE n > 0) s
WHERE regexp_replace(uv::text, '[ABC]', '', 'g') <> uv2::text;

-- Known differences from core when id order differs from string order.
-- Mapping a..i -> 9..1 (reversed).
-- (1) @@ is exact; (2) ts_rank sums operands in id order instead of string
-- order, so it may differ in the last float bits; (3) ts_rank_cd breaks ties
-- between different lexemes at the SAME position by lexeme index (core: by
-- WordEntry address = string order), so it may differ when positions are
-- shared, and is exact otherwise.
SELECT setseed(0.7);
CREATE TEMP TABLE dr AS              -- unique positions per document
SELECT n, string_agg(chr(97 + (random() * 8)::int) || ':' || p
                     || (ARRAY['', '', 'A', 'B', 'C'])[1 + (random() * 4)::int], ' ') AS txt
FROM generate_series(1, 200) n, generate_series(1, 20 + n % 30) p
GROUP BY n;
CREATE TEMP TABLE drs AS             -- shared positions: several lexemes per position
SELECT n, string_agg(chr(97 + (random() * 8)::int) || ':' || (1 + (random() * 15)::int), ' ') AS txt
FROM generate_series(1, 200) n, generate_series(1, 30) k
GROUP BY n;
CREATE TEMP TABLE qr (qs text);
INSERT INTO qr VALUES ('a | b'), ('a | b | c | d | e'), ('a & b'), ('a & b & c & d & e'),
                      ('(a | b) & c'), ('a <-> b <-> c'), ('a:A | b | c:B'), ('a & !b');
CREATE TEMP TABLE qrv AS
SELECT qs, qs::tsquery AS tq, translate(qs, 'abcdefghi', '987654321')::uidquery AS uq FROM qr;

SELECT count(*) AS pairs,
       count(*) FILTER (WHERE (t.tv @@ q.tq) <> (t.uv @@ q.uq)) AS match_mismatch,
       max(abs(ts_rank(t.tv, q.tq) - ts_rank(t.uv, q.uq))
           / greatest(ts_rank(t.tv, q.tq), 1e-20)) < 1e-6 AS rank_close,
       count(*) FILTER (WHERE ts_rank_cd(t.tv, q.tq) <> ts_rank_cd(t.uv, q.uq)) AS rank_cd_mismatch
FROM (SELECT txt::tsvector AS tv, translate(txt, 'abcdefghi', '987654321')::uidvector AS uv FROM dr) t,
     qrv q;

SELECT count(*) FILTER (WHERE (t.tv @@ q.tq) <> (t.uv @@ q.uq)) AS match_mismatch,
       count(*) FILTER (WHERE ts_rank_cd(t.tv, q.tq) <> ts_rank_cd(t.uv, q.uq)) > 0 AS rank_cd_differs_on_shared_positions
FROM (SELECT txt::tsvector AS tv, translate(txt, 'abcdefghi', '987654321')::uidvector AS uv FROM drs) t,
     qrv q;
