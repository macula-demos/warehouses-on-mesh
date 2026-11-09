#!/usr/bin/env bash
# Phase 4 gate, without the browser:
#   - the operator identity writes a site B freezer through station A;
#   - the same command id is replayed and refused;
#   - a fresh stranger identity is refused;
#   - the controller audit shows only the gateway account.
# The gateway audit is what the dashboard renders; its caller column is the
# same operator node printed by the probe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/deploy/compose.yml")
STATE="$ROOT/deploy/generated"
CODE="$ROOT/deploy/probe"

(cd "$CODE" && erlc probe.erl)

for _ in $(seq 1 60); do
  [ -s "$STATE/operator-node-id" ] && break
  sleep 1
done
if [ ! -s "$STATE/operator-node-id" ]; then
  echo "operator-node-id is missing; open the dashboard first" >&2
  exit 1
fi

echo "Resetting both controllers through the gateway account..."
for site in a b; do
  "${COMPOSE[@]}" exec -T "freezer-controller-$site" sh -c \
    'curl -fsS -u "$GATEWAY_USER:$GATEWAY_PASSWORD" -X POST http://localhost:8080/api/reset' >/dev/null
done

echo
echo "== Cross-site write, replay, stranger =="
OUT="$(docker run --rm --pids-limit -1 \
  --network warehouses-lab_mesh_net \
  -v "$STATE:/mesh:ro" \
  -v "$CODE:/probe:ro" \
  -v "warehouses-lab_operator_data:/operator:ro" \
  --entrypoint /app/erts-16.3.1/bin/erl \
  warehouses-demo/ot-gateway:dev \
  -boot /app/releases/0.1.0/start_clean \
  -config /probe/sys.config \
  -pa /app/lib/macula-18.3.0/ebin -pa /probe \
  -noshell -run probe write station-a B)"
printf '%s\n' "$OUT"

printf '%s\n' "$OUT" | grep -q 'result=ok sealed=1'
printf '%s\n' "$OUT" | grep -q 'result=command_replayed'
printf '%s\n' "$OUT" | grep -q 'result=unauthorized'

echo
echo "== Controller audits =="
"$ROOT/scripts/show-audits.sh"

for site in a b; do
  if ! "${COMPOSE[@]}" exec -T "freezer-controller-$site" \
      curl -fsS http://localhost:8080/api/audit |
      jq -e '[.entries[0:5][] | select(.user != "gateway")] | length == 0' >/dev/null; then
    echo "controller $site has a non-gateway audit row in its newest five" >&2
    exit 1
  fi
done

echo "Phase 4 gate passed: write ok and sealed, replay refused, stranger refused,"
echo "and both controllers record only the gateway account."
