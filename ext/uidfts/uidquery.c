/*
 * uidquery.c
 *		uidquery type: I/O.
 *
 * Text format is the tsquery syntax with integer operands:
 *		'12 & (37 | !5) <-> 8:AB'
 * Parsing is delegated to the core parse_tsquery(); the resulting TSQuery
 * is then repacked: operand strings are converted to int32 ids stored in
 * QueryOperand.valcrc, and the operand string area is dropped.
 */
#include "postgres.h"

#include <limits.h>

#include "catalog/pg_type.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "utils/array.h"
#include "utils/builtins.h"

#include "uidfts.h"

PG_FUNCTION_INFO_V1(uidquery_in);
PG_FUNCTION_INFO_V1(uidquery_out);
PG_FUNCTION_INFO_V1(uidquery_lexids);

static int32
parse_lexid(const char *s, int len)
{
	char	   *str = pnstrdup(s, len);
	char	   *end;
	long		id;

	errno = 0;
	id = strtol(str, &end, 10);
	if (end == str || *end != '\0' || errno != 0 ||
		id < PG_INT32_MIN || id > PG_INT32_MAX)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
				 errmsg("uidquery operand must be an integer lexeme id, got \"%s\"", str)));
	pfree(str);
	return (int32) id;
}

static void
pushval_uid(Datum opaque, TSQueryParserState state, char *strval, int lenval,
			int16 weight, bool prefix)
{
	if (prefix)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("prefix search is not supported by uidquery")));
	(void) parse_lexid(strval, lenval);	/* validate early */
	pushValue(state, strval, lenval, weight, false);
}

Datum
uidquery_in(PG_FUNCTION_ARGS)
{
	char	   *in = PG_GETARG_CSTRING(0);
	TSQuery		q = parse_tsquery(in, pushval_uid, (Datum) 0, 0);
	char	   *operand = GETOPERAND(q);
	UidQuery	res;
	QueryItem  *item;
	int			i;

	res = (UidQuery) palloc0(COMPUTESIZE(q->size, 0));
	SET_VARSIZE(res, COMPUTESIZE(q->size, 0));
	res->size = q->size;
	memcpy(GETQUERY(res), GETQUERY(q), q->size * sizeof(QueryItem));

	item = GETQUERY(res);
	for (i = 0; i < res->size; i++)
	{
		if (item[i].type != QI_VAL)
			continue;
		item[i].qoperand.valcrc =
			(uint32) parse_lexid(operand + item[i].qoperand.distance,
								 item[i].qoperand.length);
		item[i].qoperand.length = 0;
		item[i].qoperand.distance = 0;
	}

	pfree(q);
	PG_RETURN_POINTER(res);
}

/*
 * Print the polish-notation tree in infix form.  Port of infix() from
 * tsquery.c, using StringInfo.
 */
static void
infix(QueryItem **cur, StringInfo out, int parentPriority, bool rightPhraseOp)
{
	check_stack_depth();

	if ((*cur)->type == QI_VAL)
	{
		QueryOperand *op = &(*cur)->qoperand;

		appendStringInfo(out, "%d", UQ_LEXID(op));
		if (op->weight)
		{
			appendStringInfoChar(out, ':');
			if (op->weight & (1 << 3))
				appendStringInfoChar(out, 'A');
			if (op->weight & (1 << 2))
				appendStringInfoChar(out, 'B');
			if (op->weight & (1 << 1))
				appendStringInfoChar(out, 'C');
			if (op->weight & 1)
				appendStringInfoChar(out, 'D');
		}
		(*cur)++;
	}
	else if ((*cur)->qoperator.oper == OP_NOT)
	{
		int			priority = QO_PRIORITY(*cur);

		if (priority < parentPriority)
			appendStringInfoString(out, "( ");
		appendStringInfoChar(out, '!');
		(*cur)++;
		infix(cur, out, priority, false);
		if (priority < parentPriority)
			appendStringInfoString(out, " )");
	}
	else
	{
		int8		oper = (*cur)->qoperator.oper;
		int			priority = QO_PRIORITY(*cur);
		int16		distance = (*cur)->qoperator.distance;
		bool		needParenthesis;
		StringInfoData right;

		(*cur)++;
		needParenthesis = (priority < parentPriority ||
						   (oper == OP_PHRASE && rightPhraseOp));
		if (needParenthesis)
			appendStringInfoString(out, "( ");

		/* right operand comes first in polish notation */
		initStringInfo(&right);
		infix(cur, &right, priority, (oper == OP_PHRASE));

		/* left operand */
		infix(cur, out, priority, false);

		switch (oper)
		{
			case OP_OR:
				appendStringInfo(out, " | %s", right.data);
				break;
			case OP_AND:
				appendStringInfo(out, " & %s", right.data);
				break;
			case OP_PHRASE:
				if (distance != 1)
					appendStringInfo(out, " <%d> %s", distance, right.data);
				else
					appendStringInfo(out, " <-> %s", right.data);
				break;
			default:
				elog(ERROR, "unrecognized operator type: %d", oper);
		}
		pfree(right.data);

		if (needParenthesis)
			appendStringInfoString(out, " )");
	}
}

Datum
uidquery_out(PG_FUNCTION_ARGS)
{
	UidQuery	q = PG_GETARG_UIDQUERY(0);
	StringInfoData out;
	QueryItem  *cur;

	initStringInfo(&out);
	if (q->size > 0)
	{
		cur = GETQUERY(q);
		infix(&cur, &out, -1, false);
	}
	PG_RETURN_CSTRING(out.data);
}

/* all operand lexeme ids, in query order (with duplicates) */
Datum
uidquery_lexids(PG_FUNCTION_ARGS)
{
	UidQuery	q = PG_GETARG_UIDQUERY(0);
	QueryItem  *item = GETQUERY(q);
	Datum	   *d = palloc(sizeof(Datum) * Max(q->size, 1));
	int			i,
				n = 0;

	for (i = 0; i < q->size; i++)
		if (item[i].type == QI_VAL)
			d[n++] = Int32GetDatum(UQ_LEXID(&item[i].qoperand));
	PG_RETURN_ARRAYTYPE_P(construct_array(d, n, INT4OID, 4, true, TYPALIGN_INT));
}
