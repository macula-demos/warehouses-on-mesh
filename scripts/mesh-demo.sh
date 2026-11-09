#!/usr/bin/env bash
# Two sites, two federated stations, one dashboard. Site A and site B each
# dial out to their own station; the stations are linked with outbound_peers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/deploy/compose.yml")
GENERATED="$ROOT/deploy/generated"

STATION_A_IP="172.28.0.10"
STATION_B_IP="172.28.0.11"

mkdir -p "$GENERATED"
rm -f "$GENERATED/operator-node-id" \
      "$GENERATED/realm.json" "$GENERATED/realm-a.json" "$GENERATED/realm-b.json" \
      "$GENERATED/relay.pcap"

station_config() {
  local bind_ip="$1"
  local peer_json="$2"
  jq -n --arg bind "$bind_ip" --argjson peers "$peer_json" '{
    data_dir: "/var/lib/macula/station",
    bind: $bind,
    port: 4433,
    cache: {path: "/var/lib/macula/station/cache", flush_period_ms: 30000},
    admin: {bind: "127.0.0.1", port: 8443},
    puzzle_enforcement: "off",
    outbound_peers: $peers,
    bootstrap: {
      discoverers: [{module: "macula_station_via_seed_dial", opts: {wait_ms: 100}}],
      cascade_opts: {min_peers: 0, timeout_ms: 30000}
    }
  }'
}

station_status() {
  local service="$1"
  "${COMPOSE[@]}" exec -T "$service" curl -fsS http://127.0.0.1:8443/status
}

wait_station_up() {
  local service="$1"
  for _ in $(seq 1 120); do
    if station_status "$service" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "station $service did not answer /status" >&2
  return 1
}

echo "Starting the two stations as islands..."
station_config "$STATION_A_IP" '[]' >"$GENERATED/station-a.json"
station_config "$STATION_B_IP" '[]' >"$GENERATED/station-b.json"
"${COMPOSE[@]}" up -d station-a station-b
wait_station_up station-a
wait_station_up station-b

A_NODE="$(station_status station-a | jq -r .node_id)"
B_NODE="$(station_status station-b | jq -r .node_id)"
printf '%s' "$A_NODE" >"$GENERATED/station-a-node-id"
printf '%s' "$B_NODE" >"$GENERATED/station-b-node-id"
echo "Station A node id: $A_NODE"
echo "Station B node id: $B_NODE"

echo "Linking the stations with pinned outbound_peers..."
station_config "$STATION_A_IP" \
  "[{\"host\":\"station-b\",\"port\":4433,\"expected_node_id\":\"$B_NODE\"}]" \
  >"$GENERATED/station-a.json"
station_config "$STATION_B_IP" \
  "[{\"host\":\"station-a\",\"port\":4433,\"expected_node_id\":\"$A_NODE\"}]" \
  >"$GENERATED/station-b.json"

"${COMPOSE[@]}" up -d --force-recreate station-a station-b
wait_station_up station-a
wait_station_up station-b

for _ in $(seq 1 90); do
  A_PEERS="$(station_status station-a | jq -r '.swim.members // 0')"
  B_PEERS="$(station_status station-b | jq -r '.swim.members // 0')"
  if [ "$A_PEERS" -ge 1 ] && [ "$B_PEERS" -ge 1 ]; then
    break
  fi
  sleep 1
done

if [ "${A_PEERS:-0}" -lt 1 ] || [ "${B_PEERS:-0}" -lt 1 ]; then
  echo "stations did not federate; A=$A_PEERS B=$B_PEERS" >&2
  "${COMPOSE[@]}" logs --tail=80 station-a >&2 || true
  "${COMPOSE[@]}" logs --tail=80 station-b >&2 || true
  exit 1
fi
echo "Federated: station A peers=$A_PEERS, station B peers=$B_PEERS"

echo "Starting the two sites (this builds the controllers, gateways, fixture, and UI)..."
"${COMPOSE[@]}" up -d --build

echo "Waiting for the controllers..."
for _ in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T freezer-controller-a curl -fsS http://localhost:8080/api/health >/dev/null 2>&1 &&
     "${COMPOSE[@]}" exec -T freezer-controller-b curl -fsS http://localhost:8080/api/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "Waiting for the realm fixture to publish realm-a/b.json..."
for _ in $(seq 1 180); do
  if [ -s "$GENERATED/realm-a.json" ] && [ -s "$GENERATED/realm-b.json" ]; then
    break
  fi
  sleep 1
done

if [ ! -s "$GENERATED/realm-a.json" ] || [ ! -s "$GENERATED/realm-b.json" ]; then
  echo "realm files did not appear; check the ot-realm-fixture logs" >&2
  "${COMPOSE[@]}" logs --tail=120 ot-realm-fixture >&2 || true
  exit 1
fi

echo "Waiting for both gateways..."
for _ in $(seq 1 180); do
  A_OK=0
  B_OK=0
  "${COMPOSE[@]}" exec -T ot-gateway-a curl -sS --unix-socket /run/mcl/health.sock \
      http://localhost/health 2>/dev/null | jq -e '.claim.state == "issued"' >/dev/null 2>&1 && A_OK=1 || true
  "${COMPOSE[@]}" exec -T ot-gateway-b curl -sS --unix-socket /run/mcl/health.sock \
      http://localhost/health 2>/dev/null | jq -e '.claim.state == "issued"' >/dev/null 2>&1 && B_OK=1 || true
  if [ "$A_OK" -eq 1 ] && [ "$B_OK" -eq 1 ]; then
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
echo "Realm:     $(jq -r .realm "$GENERATED/realm.json")"
echo "Station A: $(jq -r .station_node_id "$GENERATED/realm-a.json")"
echo "Station B: $(jq -r .station_node_id "$GENERATED/realm-b.json")"
echo
echo "Gateway A health:"
"${COMPOSE[@]}" exec -T ot-gateway-a curl -sS --unix-socket /run/mcl/health.sock \
  http://localhost/health | jq '{claim: .claim.state, provider_grants: [.provider_grants[].procedure]}' || true
echo "Gateway B health:"
"${COMPOSE[@]}" exec -T ot-gateway-b curl -sS --unix-socket /run/mcl/health.sock \
  http://localhost/health | jq '{claim: .claim.state, provider_grants: [.provider_grants[].procedure]}' || true
echo
echo "Admin UI:  http://localhost:4000"
echo "Site A is local; site B is read and commanded through the federated relay."
