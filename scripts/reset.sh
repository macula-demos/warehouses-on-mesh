#!/usr/bin/env bash
# Reset the simulator through the controller's own gateway account, so the
# controller audit never gains an `admin` row from a lab reset.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/deploy/compose.yml")

"${COMPOSE[@]}" exec -T freezer-controller sh -c \
  'curl -fsS -u "$GATEWAY_USER:$GATEWAY_PASSWORD" -X POST http://localhost:8080/api/reset' |
  jq .

echo "Lab reset to safe temperatures."
