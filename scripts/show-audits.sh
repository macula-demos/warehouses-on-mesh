#!/usr/bin/env bash
# Read each controller's own audit from its site network. The dashboard has no
# route to either controller; this is the read-only side-channel for the
# "controller sees only the gateway account" beat.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/deploy/compose.yml")

for site in a b; do
  echo "== Controller ${site^^} audit (newest first) =="
  "${COMPOSE[@]}" exec -T "freezer-controller-$site" \
    curl -fsS http://localhost:8080/api/audit |
    jq '.entries[0:8] | map({time: .at_ms, user, action, freezer_id, result})'
  echo
done
