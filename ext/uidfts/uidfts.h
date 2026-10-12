/*
 * uidfts.h
 *		Full-text search over integer lexeme ids.
 *
 * uidvector  - analogue of tsvector: lexemes are int32 ids instead of strings.
 * uidquery   - analogue of tsquery: operands are int32 ids.
 *
 * ---------------------------------------------------------------------------
 * uidvector on-disk layout ("pair of arrays" + offsets):
 *
 *   int32         vl_len_
 *   int32         size               number of distinct lexemes
 *   int32         lexid[size]        sorted ascending, unique
 *   uint32        posend[size]       end offset (exclusive) of lexeme i
 *                                    positions in pos[]; start = posend[i-1]
 *   WordEntryPos  pos[posend[size-1]] positions (14 bit) + weight (2 bit),
 *                                    same encoding as in tsvector
 *
 * Per lexeme: 8 bytes + 2 bytes per position. For comparison, tsvector
 * spends 4 (WordEntry) + strlen + alignment + 2 (npos) + 2 per position.
 * A lexeme without positions (stripped) simply has an empty range.
 *
 * ---------------------------------------------------------------------------
 * uidquery reuses the binary layout of TSQuery (polish notation of
 * QueryItem), so that the core TS_execute() machinery (AND/OR/NOT/phrase)
 * can be used unchanged.  The differences:
 *   - QueryOperand.valcrc holds the lexeme id;
 *   - QueryOperand.length / distance are 0, there is no operand string area;
 *   - prefix search is not supported (prefix == false always).
 */
#ifndef UIDFTS_H
#define UIDFTS_H

#include "postgres.h"
#include "fmgr.h"
#include "tsearch/ts_type.h"
#include "tsearch/ts_utils.h"

typedef struct
{
	int32		vl_len_;
	int32		size;
	int32		data[FLEXIBLE_ARRAY_MEMBER];
} UidVectorData;

typedef UidVectorData *UidVector;

#define UIDV_HDRSIZE		offsetof(UidVectorData, data)
#define UIDV_CALCSIZE(n, npos) \
	(UIDV_HDRSIZE + (n) * (sizeof(int32) + sizeof(uint32)) + (npos) * sizeof(WordEntryPos))

#define UIDV_LEXIDS(v)		((int32 *) (v)->data)
#define UIDV_POSEND(v)		((uint32 *) ((v)->data + (v)->size))
#define UIDV_POSARR(v)		((WordEntryPos *) (UIDV_POSEND(v) + (v)->size))
#define UIDV_TOTALPOS(v)	((v)->size > 0 ? UIDV_POSEND(v)[(v)->size - 1] : 0)
#define UIDV_POSSTART(v, i)	((i) > 0 ? UIDV_POSEND(v)[(i) - 1] : 0)
#define UIDV_NPOS(v, i)		(UIDV_POSEND(v)[i] - UIDV_POSSTART(v, i))
#define UIDV_POSPTR(v, i)	(UIDV_POSARR(v) + UIDV_POSSTART(v, i))

#define DatumGetUidVector(X)	((UidVector) PG_DETOAST_DATUM(X))
#define PG_GETARG_UIDVECTOR(n)	DatumGetUidVector(PG_GETARG_DATUM(n))

/* uidquery is binary-compatible with TSQuery */
typedef TSQuery UidQuery;

#define UQ_LEXID(op)			((int32) (op)->valcrc)
#define PG_GETARG_UIDQUERY(n)	PG_GETARG_TSQUERY(n)

/* uidvector.c */
extern int	uidv_find(UidVector v, int32 lexid);
extern int	uidv_cnt_length(UidVector v);

#endif							/* UIDFTS_H */
