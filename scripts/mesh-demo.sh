#!/usr/bin/env bash
# Phase 1 baseline: part 1's single-site lab with no attacker and no legacy edge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/deploy/compose.yml")
GENERATED="$ROOT/deploy/generated"
STATUS_JSON="$GENERATED/station-status.json"

mkdir -p "$GENERATED"

echo "Starting the local Macula station..."
"${COMPOSE[@]}" up -d station

echo "Waiting for the station admin endpoint..."
for _ in $(seq 1 120); do
  if "${COMPOSE[@]}" exec -T station curl -fsS http://127.0.0.1:8443/status >"$STATUS_JSON" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ ! -s "$STATUS_JSON" ]; then
  echo "station did not answer /status" >&2
  exit 1
fi

NODE_ID="$(jq -r .node_id "$STATUS_JSON")"
if [ -z "$NODE_ID" ] || [ "$NODE_ID" = "null" ]; then
  echo "station /status did not carry a node_id" >&2
  cat "$STATUS_JSON" >&2
  exit 1
fi
printf '%s' "$NODE_ID" >"$GENERATED/station-node-id"
echo "Station node id: $NODE_ID"

echo "Starting the rest of the lab (this builds the gateway, fixture, controller, and UI)..."
"${COMPOSE[@]}" up -d --build

echo "Waiting for the controller..."
for _ in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T freezer-controller curl -fsS http://localhost:8080/api/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "Waiting for the realm fixture to publish realm.json..."
for _ in $(seq 1 120); do
  if [ -s "$GENERATED/realm.json" ]; then
    break
  fi
  sleep 1
done

if [ ! -s "$GENERATED/realm.json" ]; then
  echo "realm.json did not appear; check the ot-realm-fixture logs" >&2
  "${COMPOSE[@]}" logs --tail=80 ot-realm-fixture >&2 || true
  exit 1
fi

echo "Waiting for the gateway..."
for _ in $(seq 1 120); do
  if "${COMPOSE[@]}" exec -T ot-gateway curl -fsS --unix-socket /run/mcl/health.sock \
      http://localhost/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "Waiting for the admin UI..."
for _ in $(seq 1 60); do
  if curl -fsS http://localhost:4000/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo
echo "Realm:   $(jq -r .realm "$GENERATED/realm.json")"
echo "Station: $(jq -r .station_node_id "$GENERATED/realm.json")"
echo
echo "Gateway health:"
"${COMPOSE[@]}" exec -T ot-gateway curl -sS --unix-socket /run/mcl/health.sock \
  http://localhost/health | jq . || true
echo
echo "Admin UI:  http://localhost:4000"
echo "Switch the dashboard to Mesh mode. Reads are open; writes are operator-authorized and sealed."
