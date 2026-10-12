/*
 * uidvector.c
 *		uidvector type: I/O, constructor from arrays, @@ operator.
 */
#include "postgres.h"

#include <limits.h>

#include "catalog/pg_type.h"
#include "lib/stringinfo.h"
#include "utils/array.h"
#include "utils/builtins.h"

#include "uidfts.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(uidvector_in);
PG_FUNCTION_INFO_V1(uidvector_out);
PG_FUNCTION_INFO_V1(uidvector_from_arrays);
PG_FUNCTION_INFO_V1(uidvector_length);
PG_FUNCTION_INFO_V1(uidvector_lexids);
PG_FUNCTION_INFO_V1(uidvector_match_vq);
PG_FUNCTION_INFO_V1(uidvector_match_qv);

/* One lexeme occurrence, the unit uidvector is built from */
typedef struct
{
	int32		lexid;
	WordEntryPos pos;			/* valid only if haspos */
	bool		haspos;
} UidOcc;

static int
cmp_occ(const void *a, const void *b)
{
	const UidOcc *x = (const UidOcc *) a;
	const UidOcc *y = (const UidOcc *) b;

	if (x->lexid != y->lexid)
		return (x->lexid < y->lexid) ? -1 : 1;
	if (x->haspos != y->haspos)
		return x->haspos ? 1 : -1;
	if (WEP_GETPOS(x->pos) != WEP_GETPOS(y->pos))
		return (WEP_GETPOS(x->pos) < WEP_GETPOS(y->pos)) ? -1 : 1;
	return 0;
}

/*
 * Build a uidvector from an unsorted list of occurrences.
 * Semantics follow tsvector input: duplicate lexemes are merged, duplicate
 * positions are collapsed keeping the max weight, at most MAXNUMPOS
 * positions per lexeme are kept.
 */
static UidVector
build_uidvector(UidOcc *occ, int nocc)
{
	UidVector	res;
	int32	   *lexids;
	uint32	   *posend;
	WordEntryPos *pos;
	int			nlex = 0,
				npos = 0,
				lexstart = 0,
				i;

	if (nocc > 1)
		qsort(occ, nocc, sizeof(UidOcc), cmp_occ);

	/* allocate for the worst case (all lexemes distinct), compact later */
	res = (UidVector) palloc0(UIDV_CALCSIZE(nocc, nocc));
	res->size = nocc;
	lexids = UIDV_LEXIDS(res);
	posend = UIDV_POSEND(res);
	pos = UIDV_POSARR(res);

	for (i = 0; i < nocc; i++)
	{
		if (nlex == 0 || lexids[nlex - 1] != occ[i].lexid)
		{
			lexids[nlex++] = occ[i].lexid;
			lexstart = npos;
		}
		if (occ[i].haspos)
		{
			if (npos > lexstart && WEP_GETPOS(pos[npos - 1]) == WEP_GETPOS(occ[i].pos))
			{
				/* duplicate position: keep max weight */
				if (WEP_GETWEIGHT(occ[i].pos) > WEP_GETWEIGHT(pos[npos - 1]))
					WEP_SETWEIGHT(pos[npos - 1], WEP_GETWEIGHT(occ[i].pos));
			}
			else if (npos - lexstart < MAXNUMPOS)
				pos[npos++] = occ[i].pos;
		}
		posend[nlex - 1] = npos;
	}

	/*
	 * Arrays were laid out assuming size == nocc; compact them for the real
	 * nlex.  Order matters: lexids stays in place, posend and pos move left.
	 */
	res->size = nlex;
	memmove(UIDV_POSEND(res), posend, nlex * sizeof(uint32));
	memmove(UIDV_POSARR(res), pos, npos * sizeof(WordEntryPos));
	SET_VARSIZE(res, UIDV_CALCSIZE(nlex, npos));
	return res;
}

/*
 * Text format:   lexid[:pos[weight][,pos[weight]...]] ...
 * e.g.           '12:1,5A 37 40:3'
 */
Datum
uidvector_in(PG_FUNCTION_ARGS)
{
	char	   *s = PG_GETARG_CSTRING(0);
	int			cap = 64,
				nocc = 0;
	UidOcc	   *occ = palloc(sizeof(UidOcc) * cap);

	for (;;)
	{
		char	   *end;
		long		id;

		while (*s && isspace((unsigned char) *s))
			s++;
		if (!*s)
			break;

		errno = 0;
		id = strtol(s, &end, 10);
		if (end == s || errno != 0 || id < PG_INT32_MIN || id > PG_INT32_MAX)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("invalid lexeme id in uidvector: \"%s\"", s)));
		s = end;

		if (*s != ':')
		{
			if (*s && !isspace((unsigned char) *s))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
						 errmsg("syntax error in uidvector near \"%s\"", s)));
			if (nocc >= cap)
				occ = repalloc(occ, sizeof(UidOcc) * (cap *= 2));
			occ[nocc].lexid = (int32) id;
			occ[nocc].pos = 0;
			occ[nocc].haspos = false;
			nocc++;
			continue;
		}

		/* position list */
		do
		{
			long		p;
			WordEntryPos wep = 0;

			s++;				/* skip ':' or ',' */
			errno = 0;
			p = strtol(s, &end, 10);
			if (end == s || errno != 0 || p <= 0)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
						 errmsg("invalid position in uidvector near \"%s\"", s)));
			s = end;
			WEP_SETPOS(wep, LIMITPOS(p));
			switch (*s)
			{
				case 'A': case 'a': WEP_SETWEIGHT(wep, 3); s++; break;
				case 'B': case 'b': WEP_SETWEIGHT(wep, 2); s++; break;
				case 'C': case 'c': WEP_SETWEIGHT(wep, 1); s++; break;
				case 'D': case 'd': WEP_SETWEIGHT(wep, 0); s++; break;
				default: break;
			}
			if (nocc >= cap)
				occ = repalloc(occ, sizeof(UidOcc) * (cap *= 2));
			occ[nocc].lexid = (int32) id;
			occ[nocc].pos = wep;
			occ[nocc].haspos = true;
			nocc++;
		} while (*s == ',');

		if (*s && !isspace((unsigned char) *s))
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("syntax error in uidvector near \"%s\"", s)));
	}

	PG_RETURN_POINTER(build_uidvector(occ, nocc));
}

Datum
uidvector_out(PG_FUNCTION_ARGS)
{
	UidVector	v = PG_GETARG_UIDVECTOR(0);
	StringInfoData buf;
	int			i;

	initStringInfo(&buf);
	for (i = 0; i < v->size; i++)
	{
		WordEntryPos *p = UIDV_POSPTR(v, i);
		int			n = UIDV_NPOS(v, i),
					j;

		if (i > 0)
			appendStringInfoChar(&buf, ' ');
		appendStringInfo(&buf, "%d", UIDV_LEXIDS(v)[i]);
		for (j = 0; j < n; j++)
		{
			appendStringInfo(&buf, "%c%d", j == 0 ? ':' : ',', WEP_GETPOS(p[j]));
			switch (WEP_GETWEIGHT(p[j]))
			{
				case 3: appendStringInfoChar(&buf, 'A'); break;
				case 2: appendStringInfoChar(&buf, 'B'); break;
				case 1: appendStringInfoChar(&buf, 'C'); break;
				default: break;
			}
		}
	}
	PG_RETURN_CSTRING(buf.data);
}

/*
 * uidvector(lexids int4[], positions int4[] DEFAULT NULL)
 *
 * The "pair of arrays" constructor: element i means "lexeme lexids[i]
 * occurs at position positions[i]".  Arrays need not be sorted.
 * If positions is NULL, a vector without positions is built.
 */
Datum
uidvector_from_arrays(PG_FUNCTION_ARGS)
{
	ArrayType  *ids;
	ArrayType  *poss = NULL;
	Datum	   *idd,
			   *posd = NULL;
	bool	   *idn,
			   *posn = NULL;
	int			nid,
				npos = 0,
				i;
	UidOcc	   *occ;

	if (PG_ARGISNULL(0))
		PG_RETURN_NULL();
	ids = PG_GETARG_ARRAYTYPE_P(0);
	deconstruct_array(ids, INT4OID, 4, true, TYPALIGN_INT, &idd, &idn, &nid);

	if (PG_NARGS() > 1 && !PG_ARGISNULL(1))
	{
		poss = PG_GETARG_ARRAYTYPE_P(1);
		deconstruct_array(poss, INT4OID, 4, true, TYPALIGN_INT, &posd, &posn, &npos);
		if (npos != nid)
			ereport(ERROR,
					(errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
					 errmsg("lexids and positions arrays must have the same length")));
	}

	occ = palloc(sizeof(UidOcc) * Max(nid, 1));
	for (i = 0; i < nid; i++)
	{
		if (idn[i] || (posn && posn[i]))
			ereport(ERROR,
					(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
					 errmsg("uidvector arrays must not contain nulls")));
		occ[i].lexid = DatumGetInt32(idd[i]);
		occ[i].pos = 0;
		occ[i].haspos = (posd != NULL);
		if (posd)
		{
			int32		p = DatumGetInt32(posd[i]);

			if (p <= 0)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("position must be positive, got %d", p)));
			WEP_SETPOS(occ[i].pos, LIMITPOS(p));
		}
	}

	PG_RETURN_POINTER(build_uidvector(occ, nid));
}

/* number of distinct lexemes, like length(tsvector) */
Datum
uidvector_length(PG_FUNCTION_ARGS)
{
	UidVector	v = PG_GETARG_UIDVECTOR(0);

	PG_RETURN_INT32(v->size);
}

Datum
uidvector_lexids(PG_FUNCTION_ARGS)
{
	UidVector	v = PG_GETARG_UIDVECTOR(0);
	Datum	   *d = palloc(sizeof(Datum) * Max(v->size, 1));
	int			i;

	for (i = 0; i < v->size; i++)
		d[i] = Int32GetDatum(UIDV_LEXIDS(v)[i]);
	PG_RETURN_ARRAYTYPE_P(construct_array(d, v->size, INT4OID, 4, true, TYPALIGN_INT));
}

/* ---------------------------------------------------------------------- */

/* binary search: index of lexid in v, or -1 */
int
uidv_find(UidVector v, int32 lexid)
{
	int32	   *ids = UIDV_LEXIDS(v);
	int			lo = 0,
				hi = v->size;

	while (lo < hi)
	{
		int			mid = lo + (hi - lo) / 2;

		if (ids[mid] == lexid)
			return mid;
		if (ids[mid] < lexid)
			lo = mid + 1;
		else
			hi = mid;
	}
	return -1;
}

/* total number of positions (lexemes w/o positions count as 1) */
int
uidv_cnt_length(UidVector v)
{
	int			i,
				len = 0;

	for (i = 0; i < v->size; i++)
	{
		int			n = UIDV_NPOS(v, i);

		len += (n == 0) ? 1 : n;
	}
	return len;
}

/*
 * TS_execute callback: same logic as checkcondition_str + checkclass_str
 * in tsvector_op.c, minus prefix handling.
 */
static TSTernaryValue
checkcondition_uid(void *checkval, QueryOperand *val, ExecPhraseData *data)
{
	UidVector	v = (UidVector) checkval;
	int			idx = uidv_find(v, UQ_LEXID(val));
	WordEntryPos *p;
	int			n,
				j;

	if (idx < 0)
		return TS_NO;

	n = UIDV_NPOS(v, idx);
	if (n == 0)
		return data ? TS_MAYBE : TS_YES;	/* no positions stored */

	p = UIDV_POSPTR(v, idx);

	if (val->weight && data)
	{
		WordEntryPos *dptr;

		dptr = data->pos = palloc(sizeof(WordEntryPos) * n);
		data->allocated = true;
		for (j = 0; j < n; j++)
			if (val->weight & (1 << WEP_GETWEIGHT(p[j])))
				*dptr++ = WEP_GETPOS(p[j]);
		data->npos = dptr - data->pos;
		if (data->npos > 0)
			return TS_YES;
		pfree(data->pos);
		data->pos = NULL;
		data->allocated = false;
		return TS_NO;
	}
	else if (val->weight)
	{
		for (j = 0; j < n; j++)
			if (val->weight & (1 << WEP_GETWEIGHT(p[j])))
				return TS_YES;
		return TS_NO;
	}
	else if (data)
	{
		data->npos = n;
		data->pos = p;
		data->allocated = false;
	}
	return TS_YES;
}

static bool
uid_match(UidVector v, UidQuery q)
{
	if (!q->size)
		return false;
	return TS_execute(GETQUERY(q), (void *) v, TS_EXEC_EMPTY, checkcondition_uid);
}

Datum
uidvector_match_vq(PG_FUNCTION_ARGS)
{
	UidVector	v = PG_GETARG_UIDVECTOR(0);
	UidQuery	q = PG_GETARG_UIDQUERY(1);
	bool		res = uid_match(v, q);

	PG_FREE_IF_COPY(v, 0);
	PG_FREE_IF_COPY(q, 1);
	PG_RETURN_BOOL(res);
}

Datum
uidvector_match_qv(PG_FUNCTION_ARGS)
{
	UidQuery	q = PG_GETARG_UIDQUERY(0);
	UidVector	v = PG_GETARG_UIDVECTOR(1);
	bool		res = uid_match(v, q);

	PG_FREE_IF_COPY(q, 0);
	PG_FREE_IF_COPY(v, 1);
	PG_RETURN_BOOL(res);
}
