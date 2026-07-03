#!/usr/bin/env bash
# Module-boundary guards (docs/MODULES.md §2) — the layer rules, enforced by grep like the
# neutrality guard. Checks REAL `open import` lines only (comments may mention anything).
# Run from the repo root: bash scripts/check-layering.sh
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
bad() { echo "✗ layering $1"; shift; printf '%s\n' "$@"; fail=1; }

imports_of() { grep -nE "^open import" "$1" 2>/dev/null; }

# G1: IndexedMap is known ONLY to Store/Base and Store/Interface (principle 11 — the seam).
hits=$(grep -rlE "^(open )?import Agdelte.Storage.IndexedMap" Cxm --include='*.agda' \
       | grep -v -e 'Cxm/Store/Base.agda' -e 'Cxm/Store/Interface.agda')
[ -n "$hits" ] && bad "G1: IndexedMap outside the seam:" "$hits"

# G2: IO/FFI (Agdelte.FFI.*, Agdelte.Storage.WAL) only in Api, Worker, Store/Wal.
hits=$(grep -rlE "^open import (Agdelte\.FFI|Agdelte\.Storage\.WAL)" Cxm --include='*.agda' \
       | grep -v -e 'Cxm/Api.agda' -e 'Cxm/Worker.agda' -e 'Cxm/Store/Wal.agda' -e 'Cxm/Test/')
[ -n "$hits" ] && bad "G2: FFI/WAL import outside IO adapters:" "$hits"

# G3: --guardedness (infective!) only in the G2 modules + the AllIO umbrella.
hits=$(grep -rlE '\{-# OPTIONS[^}]*guardedness' Cxm --include='*.agda' \
       | grep -v -e 'Cxm/Api.agda' -e 'Cxm/Worker.agda' -e 'Cxm/Store/Wal.agda' -e 'Cxm/AllIO.agda')
[ -n "$hits" ] && bad "G3: --guardedness outside {Api,Worker,Store/Wal,AllIO}:" "$hits"

# G4: L1 records + L5 pure reads must not import Cxm.Store.* / Cxm.Commands / FFI.
#     Exception (documented, MODULES.md §1): Inference carries the Txn projector
#     rebuildHypotheses → may import Cxm.Txn + Cxm.Store.Interface (still no Wal/FFI).
L1_L5="Tenant Subject Edge Identity Event Bus Knowledge Collections Offering Resource \
Entitlement Account Payment Expectation Protocol Episode Users Appointment Num Config \
Schedule Site Fact Hypothesis Trait RelationshipState Instance Wire Version \
Query Projection Decision Social"
for m in $L1_L5; do
  f="Cxm/$m.agda"; [ -f "$f" ] || continue
  hits=$(imports_of "$f" | grep -E "Cxm\.(Store|Commands)|Agdelte\.FFI|Agdelte\.Storage\.WAL")
  [ -n "$hits" ] && bad "G4: $m imports above its layer:" "$hits"
done
hits=$(imports_of Cxm/Inference.agda | grep -E "Cxm\.Store\.Wal|Cxm\.Commands|Agdelte\.FFI")
[ -n "$hits" ] && bad "G4: Inference beyond its documented exception:" "$hits"

# G5: Commands goes through the seam only — no Wal, no FFI, no direct Base-field surgery
#     (IndexedMap covered by G1; Wal/FFI here).
hits=$(imports_of Cxm/Commands.agda | grep -E "Cxm\.Store\.Wal|Agdelte\.FFI|Agdelte\.Storage\.WAL")
[ -n "$hits" ] && bad "G5: Commands imports IO:" "$hits"

if [ "$fail" -eq 0 ]; then
  echo "✓ layering guards: OK (G1–G5, docs/MODULES.md §2)"
fi
exit "$fail"
