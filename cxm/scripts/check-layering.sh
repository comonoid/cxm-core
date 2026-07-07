#!/usr/bin/env bash
# Module-boundary guards (docs/MODULES.md §2) — the layer rules, enforced by grep like the
# neutrality guard. Checks REAL `open import` lines only (comments may mention anything).
# Run from the repo root: bash scripts/check-layering.sh
#
# POSTGRES-ONLY (2026-07-07): the WAL backend (IndexedMap/Txn/Interface/Commands/Api/Worker) was
# retired. The store is now the typed EDSL — domain modules speak verbs (Cxm.Store.Verbs) and only
# ONE module (Cxm.Store.Pg) touches the driver / IO / --guardedness.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
bad() { echo "✗ layering $1"; shift; printf '%s\n' "$@"; fail=1; }

imports_of() { grep -nE "^open import" "$1" 2>/dev/null; }

# G1: the driver/IO seam — Agdelte.FFI + the PG IO modules (Postgres/FFI/PgConn/FreeIO) are known
#     to Cxm.Store.Pg ONLY. Everything else addresses the store through verbs, never the driver.
hits=$(grep -rlE "^open import (Agdelte\.FFI|Agdelte\.Storage\.(Postgres|FFI|PgConn|FreeIO))" Cxm --include='*.agda' \
       | grep -v -e 'Cxm/Store/Pg.agda')
[ -n "$hits" ] && bad "G1: driver/IO import outside Cxm.Store.Pg:" "$hits"

# G2: --guardedness (infective!) only in Cxm.Store.Pg (the sole IO-folding module).
hits=$(grep -rlE '\{-# OPTIONS[^}]*guardedness' Cxm --include='*.agda' \
       | grep -v -e 'Cxm/Store/Pg.agda')
[ -n "$hits" ] && bad "G2: --guardedness outside Cxm.Store.Pg:" "$hits"

# G3: L1 records + L5 pure reads must not import Cxm.Store.* or the driver — they are pure domain,
#     below the store. (Inference is pure too now: a deterministic function of the event log.)
L1_L5="Tenant Subject Edge Identity Event Bus Knowledge Collections Offering Resource \
Entitlement Account Payment Expectation Protocol Episode Users Appointment Num Config \
Schedule Site Fact Hypothesis Trait RelationshipState Instance Wire Version \
Projection Decision Social Inference"
for m in $L1_L5; do
  f="Cxm/$m.agda"; [ -f "$f" ] || continue
  hits=$(imports_of "$f" | grep -E "Cxm\.Store\.|Agdelte\.FFI|Agdelte\.Storage\.(Postgres|PgConn|FreeIO|WAL)")
  [ -n "$hits" ] && bad "G3: $m imports above its layer (pure domain must not touch the store):" "$hits"
done

if [ "$fail" -eq 0 ]; then
  echo "✓ layering guards: OK (G1–G3, docs/MODULES.md §2) — Postgres-only"
fi
exit "$fail"
