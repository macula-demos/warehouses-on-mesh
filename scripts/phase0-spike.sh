#!/usr/bin/env bash
# Phase 0: prove a node dialing station A can call a procedure served by a
# node dialing station B. Timeboxed spike; no app code depends on this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/deploy/phase0/compose.yml")
GEN="$ROOT/deploy/generated/phase0"
CODE="$ROOT/deploy/phase0/spike"
STATE="$GEN/spike"

mkdir -p "$GEN" "$STATE"
rm -f "$STATE/provider-node-id" "$STATE/realm.pub"

echo "Compiling the spike module..."
(cd "$CODE" && erlc spike.erl)

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

status_json() {
  local service="$1"
  "${COMPOSE[@]}" exec -T "$service" curl -fsS http://127.0.0.1:8443/status
}

wait_up() {
  local service="$1"
  for _ in $(seq 1 120); do
    if status_json "$service" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "station $service did not answer /status" >&2
  return 1
}

# First boot: no outbound_peers yet, so each station mints/loads its identity.
station_config "172.28.0.10" '[]' >"$GEN/station-a.json"
station_config "172.28.0.11" '[]' >"$GEN/station-b.json"

echo "Starting the two stations as islands..."
"${COMPOSE[@]}" up -d station-a station-b
wait_up station-a
wait_up station-b

A_NODE="$(status_json station-a | jq -r .node_id)"
B_NODE="$(status_json station-b | jq -r .node_id)"
printf '%s' "$A_NODE" >"$GEN/station-a-node-id"
printf '%s' "$B_NODE" >"$GEN/station-b-node-id"
printf '%s' "$A_NODE" >"$STATE/station-a-node-id"
printf '%s' "$B_NODE" >"$STATE/station-b-node-id"
echo "station A: $A_NODE"
echo "station B: $B_NODE"

# Link them: each station dials the other, pinned to the identity it just minted.
station_config "172.28.0.10" "[{\"host\":\"station-b\",\"port\":4433,\"expected_node_id\":\"$B_NODE\"}]" \
  >"$GEN/station-a.json"
station_config "172.28.0.11" "[{\"host\":\"station-a\",\"port\":4433,\"expected_node_id\":\"$A_NODE\"}]" \
  >"$GEN/station-b.json"

echo "Recreating the stations with pinned outbound_peers..."
"${COMPOSE[@]}" up -d --force-recreate station-a station-b
wait_up station-a
wait_up station-b

echo "Waiting for the peer link..."
LINKED=0
for _ in $(seq 1 90); do
  A_PEERS="$(status_json station-a | jq -r '.swim.members // 0')"
  B_PEERS="$(status_json station-b | jq -r '.swim.members // 0')"
  if [ "$A_PEERS" -ge 1 ] && [ "$B_PEERS" -ge 1 ]; then
    LINKED=1
    break
  fi
  sleep 1
done

if [ "$LINKED" -ne 1 ]; then
  echo "stations did not report a peer; A=$A_PEERS B=$B_PEERS" >&2
  echo "--- station-a log ---" >&2
  "${COMPOSE[@]}" logs --tail=80 station-a >&2 || true
  echo "--- station-b log ---" >&2
  "${COMPOSE[@]}" logs --tail=80 station-b >&2 || true
  exit 1
fi

echo "Peer links: A=$A_PEERS B=$B_PEERS"

echo "Running the provider on station B..."
docker rm -f phase0-provider >/dev/null 2>&1 || true
docker run -d --name phase0-provider --pids-limit -1 \
  --network warehouses-phase0_mesh_net \
  -v "$CODE:/spikecode" \
  -v "$STATE:/spike" \
  --entrypoint /app/erts-16.3.1/bin/erl \
  ot-demo/ot-gateway:dev \
  -boot /app/releases/0.1.0/start_clean \
  -config /spikecode/sys.config \
  -pa /app/lib/macula-18.3.0/ebin -pa /spikecode \
  -noshell -run spike provider station-b 4433

echo "Waiting for the provider to advertise..."
for _ in $(seq 1 60); do
  [ -s "$STATE/provider-node-id" ] && break
  sleep 1
done
[ -s "$STATE/provider-node-id" ] || { echo "provider did not start" >&2; exit 1; }

# Give the stations one advertise gossip round (30 s) so station A holds the
# provider's advertisement.
echo "Waiting for advertisement gossip (up to 40 s)..."
sleep 35

echo "Running the caller on station A..."
docker run --rm --pids-limit -1 \
  --network warehouses-phase0_mesh_net \
  -v "$CODE:/spikecode" \
  -v "$STATE:/spike" \
  --entrypoint /app/erts-16.3.1/bin/erl \
  ot-demo/ot-gateway:dev \
  -boot /app/releases/0.1.0/start_clean \
  -config /spikecode/sys.config \
  -pa /app/lib/macula-18.3.0/ebin -pa /spikecode \
  -noshell -run spike caller station-a 4433 relay

echo
echo "Station A status:"
status_json station-a | jq '{node_id, swim}'
echo "Station A forwarded-CALL telemetry (forward_rtt means it relayed):"
"${COMPOSE[@]}" exec -T station-a curl -fsS \
  http://127.0.0.1:8443/telemetry/frames | jq '.frames.call.forward_rtt // empty'
echo "Station A call bounds:"
"${COMPOSE[@]}" exec -T station-a curl -fsS http://127.0.0.1:8443/health \
  | jq '.call_bounds'

echo
echo "Station B status:"
status_json station-b | jq '{node_id, swim}'
echo "Station B forwarded-CALL telemetry:"
"${COMPOSE[@]}" exec -T station-b curl -fsS \
  http://127.0.0.1:8443/telemetry/frames | jq '.frames.call.forward_rtt // empty'
echo "Station B call bounds:"
"${COMPOSE[@]}" exec -T station-b curl -fsS http://127.0.0.1:8443/health \
  | jq '.call_bounds'

echo
echo "Provider still running?  docker logs phase0-provider"
echo "Stop the spike:           docker rm -f phase0-provider && ${COMPOSE[*]} down -v"
