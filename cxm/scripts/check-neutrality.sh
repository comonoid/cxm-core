#!/usr/bin/env bash
# Neutrality guard (cxm-plan.md, Phase 0). The CXM core must stay domain-neutral: it must
# never name a concrete vertical. Verticals live in packs + config (principle 9), never in
# the core. Run before finishing phases 6–8 (and ideally in CI).
#
# Exit non-zero if any forbidden vertical term appears in Cxm/*.agda source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Cxm"

# Vertical vocabulary the core must not mention (case-insensitive). Cyrillic + latin.
PATTERN='psych|vet\b|veterinar|clown|курс|медцентр|психолог|ветклиник|ветеринар'

if [ ! -d "$SRC" ]; then
  echo "check-neutrality: no $SRC directory yet — nothing to check."
  exit 0
fi

# Search only Agda source; ignore comments? No — even comments naming a vertical are a smell
# in the neutral core. Report file:line for any hit.
hits="$(grep -rniE "$PATTERN" --include='*.agda' "$SRC" || true)"

if [ -n "$hits" ]; then
  echo "check-neutrality: FAIL — the neutral CXM core names a vertical:"
  echo "$hits"
  exit 1
fi

echo "check-neutrality: OK — core is domain-neutral."
