MODULE_big = uidfts
OBJS = uidvector.o uidquery.o uidrank.o
EXTENSION = uidfts
DATA = uidfts--0.1.sql
REGRESS = uidfts

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# ---------------------------------------------------------------------------
# Loading without `make install` (no root needed): the server loads the .so
# straight from this directory, objects are created in schema `public`.
#   make devload DB=fts_bench
# ---------------------------------------------------------------------------
DB ?= fts_bench
PGUSER ?= postgres

dev-install.sql: uidfts--0.1.sql
	sed -e 's|MODULE_PATHNAME|$(CURDIR)/uidfts.so|g' -e '/^\\echo/d' $< > $@

# Creates the SQL objects only if they are not there yet: a rebuilt .so is
# picked up by new sessions anyway, and dropping the types would cascade to
# every column of these types.  Use devreload to recreate from scratch.
devload: all dev-install.sql
	@if psql -U $(PGUSER) -d $(DB) -Atc "SELECT 1 FROM pg_type WHERE typname = 'uidvector'" | grep -q 1; then \
		echo "uidfts already loaded in $(DB) (.so rebuilt, SQL objects kept)"; \
	else \
		psql -U $(PGUSER) -d $(DB) -q -v ON_ERROR_STOP=1 -f dev-install.sql && echo "uidfts loaded into $(DB)"; \
	fi

# DESTRUCTIVE: drops all columns of types uidvector/uidquery in $(DB)
devreload: all dev-install.sql
	psql -U $(PGUSER) -d $(DB) -v ON_ERROR_STOP=1 -c 'DROP TYPE IF EXISTS uidvector, uidquery CASCADE' -f dev-install.sql

# Regression test without installation: fresh DB, dev-load, diff with expected/
devcheck: all dev-install.sql
	mkdir -p results
	psql -U $(PGUSER) -d postgres -qc 'DROP DATABASE IF EXISTS uidfts_regress' -c 'CREATE DATABASE uidfts_regress'
	psql -U $(PGUSER) -d uidfts_regress -q -v ON_ERROR_STOP=1 -f dev-install.sql
	sed 's/^CREATE EXTENSION uidfts;/-- (dev-loaded)/' sql/uidfts.sql | \
		psql -U $(PGUSER) -d uidfts_regress -X -a -q --no-psqlrc 2>&1 | sed 's/^psql:<stdin>:[0-9]*: //' > results/uidfts.out
	diff -u expected/uidfts.out results/uidfts.out && echo 'devcheck: PASSED'

EXTRA_CLEAN = dev-install.sql results
.PHONY: devload devreload devcheck
