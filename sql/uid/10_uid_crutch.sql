-- 10_uid_crutch.sql
-- "Crutch" text->ids pipeline for the uidfts experiment.
--
-- The uidfts extension knows nothing about strings: no parser, no
-- dictionaries.  Until those exist, documents and queries are converted
-- outside of it: the core 'english' parser/stemmer produces tsvector /
-- tsquery, and lex_dict (03_dict.sql) maps each lexeme to its int id.
--
-- Prerequisites: 03_dict.sql (lex_dict), uidfts loaded (make devload).

-- tsvector -> uidvector.  Weights are dropped (the baseline corpus has none,
-- to_tsvector() without setweight() gives only 'D').
CREATE OR REPLACE FUNCTION tsv_to_uidv(t tsvector) RETURNS uidvector
LANGUAGE sql STABLE PARALLEL SAFE
AS $$
    SELECT uidvector(coalesce(array_agg(d.id::int4), '{}'),
                     coalesce(array_agg(p::int4),    '{}'))
    FROM unnest(t) AS u
    JOIN lex_dict d ON d.lexeme = u.lexeme
    CROSS JOIN LATERAL unnest(u.positions) AS p
$$;

-- tsquery -> uidquery: replace every quoted lexeme by its id.
-- Lexemes missing from lex_dict become id 0, which matches nothing
-- (ids start from 1).  Prefix operands (:*) are not supported.
CREATE OR REPLACE FUNCTION tsq_to_uidq(q tsquery) RETURNS uidquery
LANGUAGE plpgsql STABLE STRICT
AS $$
DECLARE
    s   text := q::text;
    m   text[];
    lid bigint;
BEGIN
    FOR m IN SELECT regexp_matches(q::text, '''((?:[^'']|'''')+)''', 'g') LOOP
        SELECT d.id INTO lid FROM lex_dict d WHERE d.lexeme = replace(m[1], '''''', '''');
        s := replace(s, '''' || m[1] || '''', coalesce(lid, 0)::text);
    END LOOP;
    RETURN s::uidquery;
END;
$$;
