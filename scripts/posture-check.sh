#!/usr/bin/env bash
# Phase 5 posture check for the two-site lab.
#
# What it asserts:
#   - only the dashboard publishes a host port (4000, the browser UI);
#   - both gateways have no non-loopback TCP listener;
#   - both stations have only loopback TCP control listeners;
#   - the controllers are attached only to their site network;
#   - from the browser network, 8080/8443/502 are closed on the host and the
#     site service names do not resolve;
#   - from the relay network, the gateways and stations have no open TCP
#     port, and the controllers' site addresses are filtered;
#   - both gateways have an issued claim, so their station link is outbound.
#
# The documented exceptions: the dashboard's published 4000, the BEAM
# loopback control ports (EPMD/distribution) on the gateway and station, the
# stations' UDP 4433 mesh listener, and the gateways' outbound QUIC client UDP
# socket.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/deploy/compose.yml")

fail() {
  echo "POSTURE FAILED: $*" >&2
  exit 1
}

service_id() {
  "${COMPOSE[@]}" ps -q "$1"
}

networks_of() {
  docker inspect "$(service_id "$1")" \
    -f '{{range $n,$_ := .NetworkSettings.Networks}}{{$n}} {{end}}'
}

ip_on() {
  local service="$1"
  local network="$2"
  docker inspect "$(service_id "$service")" \
    -f "{{with index .NetworkSettings.Networks \"$network\"}}{{.IPAddress}}{{end}}"
}

scan_on() {
  local network="$1"
  shift
  docker run --rm --pids-limit -1 --network "$network" nicolaka/netshoot "$@"
}

check_networks() {
  local service="$1"
  shift
  local actual expected
  actual="$(networks_of "$service" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')"
  expected="$(printf '%s\n' "$@" | sort | tr '\n' ' ')"
  echo "  $service: $actual"
  [ "$actual" = "$expected" ] ||
    fail "$service is attached to unexpected networks ($actual)"
}

echo "== Published host ports =="
while IFS='|' read -r service publishers; do
  echo "  $service: ${publishers:-none}"
  if printf '%s' "$publishers" | grep -qE -- '-> [0-9]' && [ "$service" != "admin-ui" ]; then
    fail "$service publishes a host port"
  fi
done < <("${COMPOSE[@]}" ps --format '{{.Service}}|{{.Publishers}}')

"${COMPOSE[@]}" ps --format '{{.Service}}|{{.Publishers}}' |
  grep -Fq 'admin-ui|[4000/tcp -> 0.0.0.0:4000]' ||
  fail "the dashboard's 4000 port is not the only published listener"

echo
echo "== Gateway TCP listeners (must be loopback only) =="
for gateway in ot-gateway-a ot-gateway-b; do
  listeners="$("${COMPOSE[@]}" exec -T "$gateway" sh -c \
    'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk "NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[1]}"' |
    sort -u)"
  echo "  $gateway: ${listeners:-no TCP listener}"
  for address in $listeners; do
    case "$address" in
      0100007F|00000000000000000000000001000000) ;;
      *) fail "$gateway has a non-loopback TCP listener ($address)" ;;
    esac
  done
done

echo
echo "== Station TCP control listeners (must be loopback only) =="
for station in station-a station-b; do
  listeners="$("${COMPOSE[@]}" exec -T "$station" sh -c \
    'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk "NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[1]}"' |
    sort -u)"
  echo "  $station: ${listeners:-no TCP listener}"
  for address in $listeners; do
    case "$address" in
      0100007F|00000000000000000000000001000000) ;;
      *) fail "$station has a non-loopback TCP listener ($address)" ;;
    esac
  done
done

echo
echo "== Network attachments =="
check_networks ot-gateway-a warehouses-lab_mesh_net warehouses-lab_site_a_net
check_networks ot-gateway-b warehouses-lab_mesh_net warehouses-lab_site_b_net
check_networks freezer-controller-a warehouses-lab_site_a_net
check_networks freezer-controller-b warehouses-lab_site_b_net
check_networks station-a warehouses-lab_mesh_net
check_networks station-b warehouses-lab_mesh_net

echo
echo "== Outside scan from the browser network =="
UI_GW="$(docker network inspect warehouses-lab_ui_net \
  -f '{{(index .IPAM.Config 0).Gateway}}')"
UI_SCAN="$(scan_on warehouses-lab_ui_net \
  nmap -sT -Pn -p 4000,8080,8443,502 "$UI_GW" 2>&1)"
printf '%s\n' "$UI_SCAN" | grep -E '^[0-9]+/tcp'
printf '%s\n' "$UI_SCAN" | grep -qE '^4000/tcp[[:space:]]+open' ||
  fail "the dashboard's 4000 is not reachable from the browser network"
for port in 8080 8443 502; do
  if printf '%s\n' "$UI_SCAN" | grep -qE "^$port/tcp[[:space:]]+open"; then
    fail "host port $port is open from the browser network"
  fi
done

for name in freezer-controller-a freezer-controller-b ot-gateway-a ot-gateway-b station-a station-b; do
  if scan_on warehouses-lab_ui_net sh -c "getent hosts $name" >/dev/null 2>&1; then
    fail "$name resolves from the browser network"
  fi
done
echo "  site service names do not resolve from the browser network"

echo
echo "== TCP scan from the relay network =="
MESH_TARGETS=()
for service in ot-gateway-a ot-gateway-b station-a station-b; do
  MESH_TARGETS+=("$(ip_on "$service" warehouses-lab_mesh_net)")
done
MESH_SCAN="$(scan_on warehouses-lab_mesh_net \
  nmap -sT -Pn -p 22,80,443,502,4000,8080,8443 "${MESH_TARGETS[@]}" 2>&1)"
printf '%s\n' "$MESH_SCAN" | grep -E 'Nmap scan report|^[0-9]+/tcp'
if printf '%s\n' "$MESH_SCAN" | grep -qE '^[0-9]+/tcp[[:space:]]+open'; then
  fail "a relay-network TCP port is open"
fi

for controller in freezer-controller-a freezer-controller-b; do
  site_net="warehouses-lab_site_${controller##*-}_net"
  ip="$(ip_on "$controller" "$site_net")"
  CONTROLLER_SCAN="$(scan_on warehouses-lab_mesh_net \
    nmap -sT -Pn -p 8080,8443,502 "$ip" 2>&1)"
  if printf '%s\n' "$CONTROLLER_SCAN" | grep -qE '^[0-9]+/tcp[[:space:]]+open'; then
    fail "$controller is reachable from the relay network ($ip)"
  fi
  echo "  $controller ($ip): filtered from the relay network"
done

echo
echo "== Gateways dial out =="
for gateway in ot-gateway-a ot-gateway-b; do
  state=""
  for _ in $(seq 1 60); do
    state="$("${COMPOSE[@]}" exec -T "$gateway" curl -sS --unix-socket /run/mcl/health.sock \
      http://localhost/health 2>/dev/null | jq -r '.claim.state // empty' || true)"
    [ "$state" = "issued" ] && break
    sleep 1
  done
  echo "  $gateway claim: ${state:-unknown}"
  [ "$state" = "issued" ] || fail "$gateway has no issued claim; its station link did not work"
done

echo
echo "Posture check passed. The only host listener is the dashboard's 4000."
echo "Both gateways have no non-loopback TCP listener and dial out to their"
echo "station; both controllers are only on their site network."
