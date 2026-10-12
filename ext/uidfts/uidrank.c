/*
 * uidrank.c
 *		ts_rank / ts_rank_cd for uidvector x uidquery.
 *
 * Straight port of src/backend/utils/adt/tsrank.c (PostgreSQL 14).
 * The algorithms are kept identical; the only changes are:
 *   - lexeme lookup is a binary search over int32 ids (uidv_find) instead
 *     of tsCompareString() over strings;
 *   - query operands are sorted/deduplicated by id instead of by string;
 *   - positions are taken from the uidvector position array;
 *   - prefix matching is dropped (uidquery has no prefix operands).
 *
 * Because operands are summed in a different order (by id vs. by string),
 * ts_rank results may differ from the core ones in the last float bits.
 */
#include "postgres.h"

#include <limits.h>
#include <math.h>

#include "miscadmin.h"
#include "utils/array.h"
#include "utils/builtins.h"

#include "uidfts.h"

PG_FUNCTION_INFO_V1(uid_rank_wttf);
PG_FUNCTION_INFO_V1(uid_rank_wtt);
PG_FUNCTION_INFO_V1(uid_rank_ttf);
PG_FUNCTION_INFO_V1(uid_rank_tt);
PG_FUNCTION_INFO_V1(uid_rankcd_wttf);
PG_FUNCTION_INFO_V1(uid_rankcd_wtt);
PG_FUNCTION_INFO_V1(uid_rankcd_ttf);
PG_FUNCTION_INFO_V1(uid_rankcd_tt);

static const float weights[] = {0.1f, 0.2f, 0.4f, 1.0f};

#define wpos(wep)	( w[ WEP_GETWEIGHT(wep) ] )

#define RANK_NO_NORM			0x00
#define RANK_NORM_LOGLENGTH		0x01
#define RANK_NORM_LENGTH		0x02
#define RANK_NORM_EXTDIST		0x04
#define RANK_NORM_UNIQ			0x08
#define RANK_NORM_LOGUNIQ		0x10
#define RANK_NORM_RDIVRPLUS1	0x20
#define DEF_NORM_METHOD			RANK_NO_NORM

static float calc_rank_or(const float *w, UidVector t, UidQuery q);
static float calc_rank_and(const float *w, UidVector t, UidQuery q);

static float4
word_distance(int32 w)
{
	if (w > 100)
		return 1e-30f;

	return 1.0 / (1.005 + 0.05 * exp(((float4) w) / 1.5 - 2));
}

static int
compareQueryOperand(const void *a, const void *b)
{
	int32		ia = UQ_LEXID(*(QueryOperand *const *) a);
	int32		ib = UQ_LEXID(*(QueryOperand *const *) b);

	return (ia < ib) ? -1 : (ia > ib) ? 1 : 0;
}

/* sorted, de-duplicated array of operand pointers; length in *size */
static QueryOperand **
SortAndUniqItems(UidQuery q, int *size)
{
	QueryItem  *item = GETQUERY(q);
	QueryOperand **res,
			  **ptr,
			  **prevptr;

	ptr = res = (QueryOperand **) palloc(sizeof(QueryOperand *) * *size);

	while ((*size)--)
	{
		if (item->type == QI_VAL)
		{
			*ptr = (QueryOperand *) item;
			ptr++;
		}
		item++;
	}

	*size = ptr - res;
	if (*size < 2)
		return res;

	qsort(res, *size, sizeof(QueryOperand *), compareQueryOperand);

	ptr = res + 1;
	prevptr = res;
	while (ptr - res < *size)
	{
		if (compareQueryOperand((void *) ptr, (void *) prevptr) != 0)
		{
			prevptr++;
			*prevptr = *ptr;
		}
		ptr++;
	}

	*size = prevptr + 1 - res;
	return res;
}

static float
calc_rank_and(const float *w, UidVector t, UidQuery q)
{
	WordEntryPos **pos;
	int		   *npos;
	WordEntryPos posnull;
	int			i,
				k,
				l,
				p,
				idx;
	WordEntryPos *post,
			   *ct;
	int32		dimt,
				lenct,
				dist;
	float		res = -1.0;
	QueryOperand **item;
	int			size = q->size;

	item = SortAndUniqItems(q, &size);
	if (size < 2)
	{
		pfree(item);
		return calc_rank_or(w, t, q);
	}
	pos = (WordEntryPos **) palloc0(sizeof(WordEntryPos *) * q->size);
	npos = (int *) palloc0(sizeof(int) * q->size);

	/* dummy position to use when the lexeme has no positions */
	posnull = 0;
	WEP_SETPOS(posnull, MAXENTRYPOS - 1);

	for (i = 0; i < size; i++)
	{
		idx = uidv_find(t, UQ_LEXID(item[i]));
		if (idx < 0)
			continue;

		if (UIDV_NPOS(t, idx) > 0)
		{
			pos[i] = UIDV_POSPTR(t, idx);
			npos[i] = UIDV_NPOS(t, idx);
		}
		else
		{
			pos[i] = &posnull;
			npos[i] = 1;
		}

		dimt = npos[i];
		post = pos[i];
		for (k = 0; k < i; k++)
		{
			if (!pos[k])
				continue;
			lenct = npos[k];
			ct = pos[k];
			for (l = 0; l < dimt; l++)
			{
				for (p = 0; p < lenct; p++)
				{
					dist = Abs((int) WEP_GETPOS(post[l]) - (int) WEP_GETPOS(ct[p]));
					if (dist || (dist == 0 && (pos[i] == &posnull || pos[k] == &posnull)))
					{
						float		curw;

						if (!dist)
							dist = MAXENTRYPOS;
						curw = sqrt(wpos(post[l]) * wpos(ct[p]) * word_distance(dist));
						res = (res < 0) ? curw : 1.0 - (1.0 - res) * (1.0 - curw);
					}
				}
			}
		}
	}
	pfree(pos);
	pfree(npos);
	pfree(item);
	return res;
}

static float
calc_rank_or(const float *w, UidVector t, UidQuery q)
{
	WordEntryPos posnull = 0;
	WordEntryPos *post;
	int32		dimt,
				j,
				i,
				idx;
	float		res = 0.0;
	QueryOperand **item;
	int			size = q->size;

	item = SortAndUniqItems(q, &size);

	for (i = 0; i < size; i++)
	{
		float		resj,
					wjm;
		int32		jm;

		idx = uidv_find(t, UQ_LEXID(item[i]));
		if (idx < 0)
			continue;

		if (UIDV_NPOS(t, idx) > 0)
		{
			dimt = UIDV_NPOS(t, idx);
			post = UIDV_POSPTR(t, idx);
		}
		else
		{
			dimt = 1;
			post = &posnull;
		}

		resj = 0.0;
		wjm = -1.0;
		jm = 0;
		for (j = 0; j < dimt; j++)
		{
			resj = resj + wpos(post[j]) / ((j + 1) * (j + 1));
			if (wpos(post[j]) > wjm)
			{
				wjm = wpos(post[j]);
				jm = j;
			}
		}
		res = res + (wjm + resj - wjm / ((jm + 1) * (jm + 1))) / 1.64493406685;
	}
	if (size > 0)
		res = res / size;
	pfree(item);
	return res;
}

static float
calc_rank(const float *w, UidVector t, UidQuery q, int32 method)
{
	QueryItem  *item = GETQUERY(q);
	float		res = 0.0;
	int			len;

	if (!t->size || !q->size)
		return 0.0;

	res = (item->type == QI_OPR && (item->qoperator.oper == OP_AND ||
									item->qoperator.oper == OP_PHRASE)) ?
		calc_rank_and(w, t, q) :
		calc_rank_or(w, t, q);

	if (res < 0)
		res = 1e-20f;

	if ((method & RANK_NORM_LOGLENGTH) && t->size > 0)
		res /= log((double) (uidv_cnt_length(t) + 1)) / log(2.0);

	if (method & RANK_NORM_LENGTH)
	{
		len = uidv_cnt_length(t);
		if (len > 0)
			res /= (float) len;
	}

	if ((method & RANK_NORM_UNIQ) && t->size > 0)
		res /= (float) (t->size);

	if ((method & RANK_NORM_LOGUNIQ) && t->size > 0)
		res /= log((double) (t->size + 1)) / log(2.0);

	if (method & RANK_NORM_RDIVRPLUS1)
		res /= (res + 1);

	return res;
}

static const float *
getWeights(ArrayType *win)
{
	static float ws[lengthof(weights)];
	int			i;
	float4	   *arrdata;

	if (win == NULL)
		return weights;

	if (ARR_NDIM(win) != 1)
		ereport(ERROR,
				(errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
				 errmsg("array of weight must be one-dimensional")));

	if (ArrayGetNItems(ARR_NDIM(win), ARR_DIMS(win)) < lengthof(weights))
		ereport(ERROR,
				(errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
				 errmsg("array of weight is too short")));

	if (array_contains_nulls(win))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("array of weight must not contain nulls")));

	arrdata = (float4 *) ARR_DATA_PTR(win);
	for (i = 0; i < lengthof(weights); i++)
	{
		ws[i] = (arrdata[i] >= 0) ? arrdata[i] : weights[i];
		if (ws[i] > 1.0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("weight out of range")));
	}

	return ws;
}

Datum
uid_rank_wttf(PG_FUNCTION_ARGS)
{
	ArrayType  *win = (ArrayType *) PG_DETOAST_DATUM(PG_GETARG_DATUM(0));
	UidVector	txt = PG_GETARG_UIDVECTOR(1);
	UidQuery	query = PG_GETARG_UIDQUERY(2);
	int			method = PG_GETARG_INT32(3);
	float		res;

	res = calc_rank(getWeights(win), txt, query, method);

	PG_FREE_IF_COPY(win, 0);
	PG_FREE_IF_COPY(txt, 1);
	PG_FREE_IF_COPY(query, 2);
	PG_RETURN_FLOAT4(res);
}

Datum
uid_rank_wtt(PG_FUNCTION_ARGS)
{
	ArrayType  *win = (ArrayType *) PG_DETOAST_DATUM(PG_GETARG_DATUM(0));
	UidVector	txt = PG_GETARG_UIDVECTOR(1);
	UidQuery	query = PG_GETARG_UIDQUERY(2);
	float		res;

	res = calc_rank(getWeights(win), txt, query, DEF_NORM_METHOD);

	PG_FREE_IF_COPY(win, 0);
	PG_FREE_IF_COPY(txt, 1);
	PG_FREE_IF_COPY(query, 2);
	PG_RETURN_FLOAT4(res);
}

Datum
uid_rank_ttf(PG_FUNCTION_ARGS)
{
	UidVector	txt = PG_GETARG_UIDVECTOR(0);
	UidQuery	query = PG_GETARG_UIDQUERY(1);
	int			method = PG_GETARG_INT32(2);
	float		res;

	res = calc_rank(getWeights(NULL), txt, query, method);

	PG_FREE_IF_COPY(txt, 0);
	PG_FREE_IF_COPY(query, 1);
	PG_RETURN_FLOAT4(res);
}

Datum
uid_rank_tt(PG_FUNCTION_ARGS)
{
	UidVector	txt = PG_GETARG_UIDVECTOR(0);
	UidQuery	query = PG_GETARG_UIDQUERY(1);
	float		res;

	res = calc_rank(getWeights(NULL), txt, query, DEF_NORM_METHOD);

	PG_FREE_IF_COPY(txt, 0);
	PG_FREE_IF_COPY(query, 1);
	PG_RETURN_FLOAT4(res);
}

/* ------------------------------------------------------------------------
 * Cover density ranking
 * ------------------------------------------------------------------------ */

typedef struct
{
	union
	{
		struct
		{						/* compiled doc representation */
			QueryItem **items;
			int16		nitem;
		}			query;
		struct
		{						/* used while preparing doc representation */
			QueryItem  *item;
			int			entry;	/* lexeme index in uidvector */
		}			map;
	}			data;
	WordEntryPos pos;
} DocRepresentation;

static int
compareDocR(const void *va, const void *vb)
{
	const DocRepresentation *a = (const DocRepresentation *) va;
	const DocRepresentation *b = (const DocRepresentation *) vb;

	if (WEP_GETPOS(a->pos) == WEP_GETPOS(b->pos))
	{
		if (WEP_GETWEIGHT(a->pos) == WEP_GETWEIGHT(b->pos))
		{
			if (a->data.map.entry == b->data.map.entry)
				return 0;

			return (a->data.map.entry > b->data.map.entry) ? 1 : -1;
		}

		return (WEP_GETWEIGHT(a->pos) > WEP_GETWEIGHT(b->pos)) ? 1 : -1;
	}

	return (WEP_GETPOS(a->pos) > WEP_GETPOS(b->pos)) ? 1 : -1;
}

#define MAXQROPOS	MAXENTRYPOS
typedef struct
{
	bool		operandexists;
	bool		reverseinsert;	/* true means descending insert order */
	uint32		npos;
	WordEntryPos pos[MAXQROPOS];
} QueryRepresentationOperand;

typedef struct
{
	UidQuery	query;
	QueryRepresentationOperand *operandData;
} QueryRepresentation;

#define QR_GET_OPERAND_DATA(q, v) \
	( (q)->operandData + (((QueryItem*)(v)) - GETQUERY((q)->query)) )

static TSTernaryValue
checkcondition_QueryOperand(void *checkval, QueryOperand *val,
							ExecPhraseData *data)
{
	QueryRepresentation *qr = (QueryRepresentation *) checkval;
	QueryRepresentationOperand *opData = QR_GET_OPERAND_DATA(qr, val);

	if (!opData->operandexists)
		return TS_NO;

	if (data)
	{
		data->npos = opData->npos;
		data->pos = opData->pos;
		if (opData->reverseinsert)
			data->pos += MAXQROPOS - opData->npos;
	}

	return TS_YES;
}

typedef struct
{
	int			pos;
	int			p;
	int			q;
	DocRepresentation *begin;
	DocRepresentation *end;
} CoverExt;

static void
resetQueryRepresentation(QueryRepresentation *qr, bool reverseinsert)
{
	int			i;

	for (i = 0; i < qr->query->size; i++)
	{
		qr->operandData[i].operandexists = false;
		qr->operandData[i].reverseinsert = reverseinsert;
		qr->operandData[i].npos = 0;
	}
}

static void
fillQueryRepresentationData(QueryRepresentation *qr, DocRepresentation *entry)
{
	int			i;
	int			lastPos;
	QueryRepresentationOperand *opData;

	for (i = 0; i < entry->data.query.nitem; i++)
	{
		if (entry->data.query.items[i]->type != QI_VAL)
			continue;

		opData = QR_GET_OPERAND_DATA(qr, entry->data.query.items[i]);

		opData->operandexists = true;

		if (opData->npos == 0)
		{
			lastPos = (opData->reverseinsert) ? (MAXQROPOS - 1) : 0;
			opData->pos[lastPos] = entry->pos;
			opData->npos++;
			continue;
		}

		lastPos = opData->reverseinsert ?
			(MAXQROPOS - opData->npos) :
			(opData->npos - 1);

		if (WEP_GETPOS(opData->pos[lastPos]) != WEP_GETPOS(entry->pos))
		{
			lastPos = opData->reverseinsert ?
				(MAXQROPOS - 1 - opData->npos) :
				(opData->npos);

			opData->pos[lastPos] = entry->pos;
			opData->npos++;
		}
	}
}

static bool
Cover(DocRepresentation *doc, int len, QueryRepresentation *qr, CoverExt *ext)
{
	DocRepresentation *ptr;
	int			lastpos = ext->pos;
	bool		found = false;

	check_stack_depth();

	resetQueryRepresentation(qr, false);

	ext->p = INT_MAX;
	ext->q = 0;
	ptr = doc + ext->pos;

	/* find upper bound of cover from current position, move up */
	while (ptr - doc < len)
	{
		fillQueryRepresentationData(qr, ptr);

		if (TS_execute(GETQUERY(qr->query), (void *) qr,
					   TS_EXEC_EMPTY, checkcondition_QueryOperand))
		{
			if (WEP_GETPOS(ptr->pos) > ext->q)
			{
				ext->q = WEP_GETPOS(ptr->pos);
				ext->end = ptr;
				lastpos = ptr - doc;
				found = true;
			}
			break;
		}
		ptr++;
	}

	if (!found)
		return false;

	resetQueryRepresentation(qr, true);

	ptr = doc + lastpos;

	/* find lower bound of cover from found upper bound, move down */
	while (ptr >= doc + ext->pos)
	{
		fillQueryRepresentationData(qr, ptr);

		if (TS_execute(GETQUERY(qr->query), (void *) qr,
					   TS_EXEC_EMPTY, checkcondition_QueryOperand))
		{
			if (WEP_GETPOS(ptr->pos) < ext->p)
			{
				ext->begin = ptr;
				ext->p = WEP_GETPOS(ptr->pos);
			}
			break;
		}
		ptr--;
	}

	if (ext->p <= ext->q)
	{
		ext->pos = (ptr - doc) + 1;
		return true;
	}

	ext->pos++;
	return Cover(doc, len, qr, ext);
}

static DocRepresentation *
get_docrep(UidVector txt, QueryRepresentation *qr, int *doclen)
{
	QueryItem  *item = GETQUERY(qr->query);
	WordEntryPos *post;
	int32		dimt,
				j,
				i,
				idx;
	int			len = qr->query->size * 4,
				cur = 0;
	DocRepresentation *doc;

	doc = (DocRepresentation *) palloc(sizeof(DocRepresentation) * len);

	for (i = 0; i < qr->query->size; i++)
	{
		QueryOperand *curoperand;

		if (item[i].type != QI_VAL)
			continue;

		curoperand = &item[i].qoperand;

		idx = uidv_find(txt, UQ_LEXID(curoperand));
		if (idx < 0)
			continue;

		dimt = UIDV_NPOS(txt, idx);
		if (dimt == 0)
			continue;			/* ignore words without positions */
		post = UIDV_POSPTR(txt, idx);

		while (cur + dimt >= len)
		{
			len *= 2;
			doc = (DocRepresentation *) repalloc(doc, sizeof(DocRepresentation) * len);
		}

		for (j = 0; j < dimt; j++)
		{
			if (curoperand->weight == 0 ||
				curoperand->weight & (1 << WEP_GETWEIGHT(post[j])))
			{
				doc[cur].pos = post[j];
				doc[cur].data.map.entry = idx;
				doc[cur].data.map.item = (QueryItem *) curoperand;
				cur++;
			}
		}
	}

	if (cur > 0)
	{
		DocRepresentation *rptr = doc + 1,
				   *wptr = doc,
					storage;

		qsort((void *) doc, cur, sizeof(DocRepresentation), compareDocR);

		/* join QueryItems per lexeme and position */
		storage.pos = doc->pos;
		storage.data.query.items = palloc(sizeof(QueryItem *) * qr->query->size);
		storage.data.query.items[0] = doc->data.map.item;
		storage.data.query.nitem = 1;

		while (rptr - doc < cur)
		{
			if (rptr->pos == (rptr - 1)->pos &&
				rptr->data.map.entry == (rptr - 1)->data.map.entry)
			{
				storage.data.query.items[storage.data.query.nitem] = rptr->data.map.item;
				storage.data.query.nitem++;
			}
			else
			{
				*wptr = storage;
				wptr++;
				storage.pos = rptr->pos;
				storage.data.query.items = palloc(sizeof(QueryItem *) * qr->query->size);
				storage.data.query.items[0] = rptr->data.map.item;
				storage.data.query.nitem = 1;
			}

			rptr++;
		}

		*wptr = storage;
		wptr++;

		*doclen = wptr - doc;
		return doc;
	}

	pfree(doc);
	return NULL;
}

static float4
calc_rank_cd(const float4 *arrdata, UidVector txt, UidQuery query, int method)
{
	DocRepresentation *doc;
	int			len,
				i,
				doclen = 0;
	CoverExt	ext;
	double		Wdoc = 0.0;
	double		invws[lengthof(weights)];
	double		SumDist = 0.0,
				PrevExtPos = 0.0;
	int			NExtent = 0;
	QueryRepresentation qr;

	for (i = 0; i < lengthof(weights); i++)
	{
		invws[i] = ((double) ((arrdata[i] >= 0) ? arrdata[i] : weights[i]));
		if (invws[i] > 1.0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("weight out of range")));
		invws[i] = 1.0 / invws[i];
	}

	qr.query = query;
	qr.operandData = (QueryRepresentationOperand *)
		palloc0(sizeof(QueryRepresentationOperand) * query->size);

	doc = get_docrep(txt, &qr, &doclen);
	if (!doc)
	{
		pfree(qr.operandData);
		return 0.0;
	}

	MemSet(&ext, 0, sizeof(CoverExt));
	while (Cover(doc, doclen, &qr, &ext))
	{
		double		Cpos = 0.0;
		double		InvSum = 0.0;
		double		CurExtPos;
		int			nNoise;
		DocRepresentation *ptr = ext.begin;

		while (ptr <= ext.end)
		{
			InvSum += invws[WEP_GETWEIGHT(ptr->pos)];
			ptr++;
		}

		Cpos = ((double) (ext.end - ext.begin + 1)) / InvSum;

		nNoise = (ext.q - ext.p) - (ext.end - ext.begin);
		if (nNoise < 0)
			nNoise = (ext.end - ext.begin) / 2;
		Wdoc += Cpos / ((double) (1 + nNoise));

		CurExtPos = ((double) (ext.q + ext.p)) / 2.0;
		if (NExtent > 0 && CurExtPos > PrevExtPos)
			SumDist += 1.0 / (CurExtPos - PrevExtPos);

		PrevExtPos = CurExtPos;
		NExtent++;
	}

	if ((method & RANK_NORM_LOGLENGTH) && txt->size > 0)
		Wdoc /= log((double) (uidv_cnt_length(txt) + 1));

	if (method & RANK_NORM_LENGTH)
	{
		len = uidv_cnt_length(txt);
		if (len > 0)
			Wdoc /= (double) len;
	}

	if ((method & RANK_NORM_EXTDIST) && NExtent > 0 && SumDist > 0)
		Wdoc /= ((double) NExtent) / SumDist;

	if ((method & RANK_NORM_UNIQ) && txt->size > 0)
		Wdoc /= (double) (txt->size);

	if ((method & RANK_NORM_LOGUNIQ) && txt->size > 0)
		Wdoc /= log((double) (txt->size + 1)) / log(2.0);

	if (method & RANK_NORM_RDIVRPLUS1)
		Wdoc /= (Wdoc + 1);

	pfree(doc);

	pfree(qr.operandData);

	return (float4) Wdoc;
}

Datum
uid_rankcd_wttf(PG_FUNCTION_ARGS)
{
	ArrayType  *win = (ArrayType *) PG_DETOAST_DATUM(PG_GETARG_DATUM(0));
	UidVector	txt = PG_GETARG_UIDVECTOR(1);
	UidQuery	query = PG_GETARG_UIDQUERY(2);
	int			method = PG_GETARG_INT32(3);
	float		res;

	res = calc_rank_cd(getWeights(win), txt, query, method);

	PG_FREE_IF_COPY(win, 0);
	PG_FREE_IF_COPY(txt, 1);
	PG_FREE_IF_COPY(query, 2);
	PG_RETURN_FLOAT4(res);
}

Datum
uid_rankcd_wtt(PG_FUNCTION_ARGS)
{
	ArrayType  *win = (ArrayType *) PG_DETOAST_DATUM(PG_GETARG_DATUM(0));
	UidVector	txt = PG_GETARG_UIDVECTOR(1);
	UidQuery	query = PG_GETARG_UIDQUERY(2);
	float		res;

	res = calc_rank_cd(getWeights(win), txt, query, DEF_NORM_METHOD);

	PG_FREE_IF_COPY(win, 0);
	PG_FREE_IF_COPY(txt, 1);
	PG_FREE_IF_COPY(query, 2);
	PG_RETURN_FLOAT4(res);
}

Datum
uid_rankcd_ttf(PG_FUNCTION_ARGS)
{
	UidVector	txt = PG_GETARG_UIDVECTOR(0);
	UidQuery	query = PG_GETARG_UIDQUERY(1);
	int			method = PG_GETARG_INT32(2);
	float		res;

	res = calc_rank_cd(getWeights(NULL), txt, query, method);

	PG_FREE_IF_COPY(txt, 0);
	PG_FREE_IF_COPY(query, 1);
	PG_RETURN_FLOAT4(res);
}

Datum
uid_rankcd_tt(PG_FUNCTION_ARGS)
{
	UidVector	txt = PG_GETARG_UIDVECTOR(0);
	UidQuery	query = PG_GETARG_UIDQUERY(1);
	float		res;

	res = calc_rank_cd(getWeights(NULL), txt, query, DEF_NORM_METHOD);

	PG_FREE_IF_COPY(txt, 0);
	PG_FREE_IF_COPY(query, 1);
	PG_RETURN_FLOAT4(res);
}
