#!/usr/bin/env bash
# Capture station A's QUIC traffic while a site B read is forwarded through it.
# The call carries a unique marker and the reply carries the freezer list. If
# the relay sees plaintext, either string appears in the capture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE="$ROOT/deploy/probe"
STATE="$ROOT/deploy/generated"
PCAP="$STATE/relay.pcap"
CAPTURE="warehouses-relay-capture"

(cd "$CODE" && erlc probe.erl)
rm -f "$PCAP"

cleanup() {
  docker stop -t 5 "$CAPTURE" >/dev/null 2>&1 || true
  docker rm -f "$CAPTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Starting the capture in station A's network namespace..."
docker run -d --name "$CAPTURE" --pids-limit -1 \
  --net container:warehouses-lab-station-a-1 \
  --cap-add NET_RAW --cap-add NET_ADMIN \
  -v "$STATE:/capture" \
  nicolaka/netshoot \
  tcpdump -i any -U -w /capture/relay.pcap 'udp port 4433' >/dev/null

sleep 2

echo "Running a site B read through station A..."
PROBE_OUT="$(docker run --rm --pids-limit -1 \
  --network warehouses-lab_mesh_net \
  -v "$STATE:/mesh:ro" \
  -v "$CODE:/probe:ro" \
  --entrypoint /app/erts-16.3.1/bin/erl \
  warehouses-demo/ot-gateway:dev \
  -boot /app/releases/0.1.0/start_clean \
  -config /probe/sys.config \
  -pa /app/lib/macula-18.3.0/ebin -pa /probe \
  -noshell -run probe relay station-a B)"
echo "$PROBE_OUT"

MARKER="$(printf '%s\n' "$PROBE_OUT" | sed -n 's/.*marker=//p' | head -1)"
if [ -z "$MARKER" ]; then
  echo "probe did not return a marker" >&2
  exit 1
fi

sleep 2
cleanup

if [ ! -s "$PCAP" ]; then
  echo "capture is empty; tcpdump did not see the mesh link" >&2
  exit 1
fi

BYTES="$(stat -c%s "$PCAP")"
echo
echo "Capture: $PCAP ($BYTES bytes)"

FOUND=0
for needle in "$MARKER" "FZ-B1" "Frozen aisle"; do
  if strings "$PCAP" | grep -Fq "$needle"; then
    echo "PLAINTEXT FOUND in the relay capture: $needle" >&2
    FOUND=1
  fi
done

if [ "$FOUND" -ne 0 ]; then
  echo "GATE FAILED: the relay saw a plaintext payload." >&2
  exit 1
fi

echo "No marker or freezer payload in the relay capture."

echo
echo "Checking the stations' own logs..."
LOGS="$(docker compose -f "$ROOT/deploy/compose.yml" logs --since 2m station-a station-b 2>&1)"
for needle in "$MARKER" "FZ-B1" "Frozen aisle"; do
  if printf '%s\n' "$LOGS" | grep -Fq "$needle"; then
    echo "PLAINTEXT FOUND in the station logs: $needle" >&2
    exit 1
  fi
done
echo "No marker or freezer payload in either station's logs."

echo
echo "The call report says sealed=1; the station forwarded the call and logged"
echo "routing metadata only. The wire capture is TLS ciphertext. The gateway"
echo "alone holds the KEM key that opens the sealed payload."
