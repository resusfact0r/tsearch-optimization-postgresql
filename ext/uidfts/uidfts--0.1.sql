\echo Use "CREATE EXTENSION uidfts" to load this file. \quit

-- ---------------------------------------------------------------------------
-- uidvector: lexemes are int4 ids
-- ---------------------------------------------------------------------------
CREATE TYPE uidvector;

CREATE FUNCTION uidvector_in(cstring) RETURNS uidvector
    AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION uidvector_out(uidvector) RETURNS cstring
    AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE uidvector (
    INPUT          = uidvector_in,
    OUTPUT         = uidvector_out,
    INTERNALLENGTH = VARIABLE,
    ALIGNMENT      = int4,
    STORAGE        = extended
);

-- "pair of arrays" constructor: lexids[i] occurs at positions[i]
CREATE FUNCTION uidvector(lexids int4[], positions int4[] DEFAULT NULL) RETURNS uidvector
    AS 'MODULE_PATHNAME', 'uidvector_from_arrays' LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION length(uidvector) RETURNS int4
    AS 'MODULE_PATHNAME', 'uidvector_length' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION uid_lexids(uidvector) RETURNS int4[]
    AS 'MODULE_PATHNAME', 'uidvector_lexids' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- uidquery: tsquery syntax with int4 operands, e.g. '12 & (37 | !5) <-> 8'
-- ---------------------------------------------------------------------------
CREATE TYPE uidquery;

CREATE FUNCTION uidquery_in(cstring) RETURNS uidquery
    AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION uidquery_out(uidquery) RETURNS cstring
    AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE uidquery (
    INPUT          = uidquery_in,
    OUTPUT         = uidquery_out,
    INTERNALLENGTH = VARIABLE,
    ALIGNMENT      = int4,
    STORAGE        = plain
);

CREATE FUNCTION uid_lexids(uidquery) RETURNS int4[]
    AS 'MODULE_PATHNAME', 'uidquery_lexids' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- match
-- ---------------------------------------------------------------------------
CREATE FUNCTION uid_match_vq(uidvector, uidquery) RETURNS bool
    AS 'MODULE_PATHNAME', 'uidvector_match_vq' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION uid_match_qv(uidquery, uidvector) RETURNS bool
    AS 'MODULE_PATHNAME', 'uidvector_match_qv' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR @@ (
    LEFTARG = uidvector, RIGHTARG = uidquery, PROCEDURE = uid_match_vq,
    COMMUTATOR = '@@', RESTRICT = contsel, JOIN = contjoinsel
);
CREATE OPERATOR @@ (
    LEFTARG = uidquery, RIGHTARG = uidvector, PROCEDURE = uid_match_qv,
    COMMUTATOR = '@@', RESTRICT = contsel, JOIN = contjoinsel
);

-- ---------------------------------------------------------------------------
-- ranking: same signatures as the core ts_rank / ts_rank_cd
-- ---------------------------------------------------------------------------
CREATE FUNCTION ts_rank(float4[], uidvector, uidquery, int4) RETURNS float4
    AS 'MODULE_PATHNAME', 'uid_rank_wttf' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION ts_rank(float4[], uidvector, uidquery) RETURNS float4
    AS 'MODULE_PATHNAME', 'uid_rank_wtt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION ts_rank(uidvector, uidquery, int4) RETURNS float4
    AS 'MODULE_PATHNAME', 'uid_rank_ttf' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION ts_rank(uidvector, uidquery) RETURNS float4
    AS 'MODULE_PATHNAME', 'uid_rank_tt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ts_rank_cd(float4[], uidvector, uidquery, int4) RETURNS float4
    AS 'MODULE_PATHNAME', 'uid_rankcd_wttf' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION ts_rank_cd(float4[], uidvector, uidquery) RETURNS float4
    AS 'MODULE_PATHNAME', 'uid_rankcd_wtt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION ts_rank_cd(uidvector, uidquery, int4) RETURNS float4
    AS 'MODULE_PATHNAME', 'uid_rankcd_ttf' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION ts_rank_cd(uidvector, uidquery) RETURNS float4
    AS 'MODULE_PATHNAME', 'uid_rankcd_tt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
