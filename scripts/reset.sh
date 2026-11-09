#!/usr/bin/env bash
# Reset both simulators through the controllers' own gateway account, so the
# controller audit never gains an `admin` row from a lab reset.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/deploy/compose.yml")

for site in a b; do
  "${COMPOSE[@]}" exec -T "freezer-controller-$site" sh -c \
    'curl -fsS -u "$GATEWAY_USER:$GATEWAY_PASSWORD" -X POST http://localhost:8080/api/reset' |
    jq .
done

echo "Lab reset to safe temperatures at both sites."
