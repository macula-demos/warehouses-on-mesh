#!/usr/bin/env bash
# Prove each site's LOCAL path independently of the dashboard: a node dialing
# station A calls gateway A through station A; a node dialing station B calls
# gateway B through station B. Both calls must be sealed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE="$ROOT/deploy/probe"
STATE="$ROOT/deploy/generated"

(cd "$CODE" && erlc probe.erl)

probe() {
  local station="$1"
  local site="$2"
  docker run --rm --pids-limit -1 \
    --network warehouses-lab_mesh_net \
    -v "$STATE:/mesh:ro" \
    -v "$CODE:/probe:ro" \
    --entrypoint /app/erts-16.3.1/bin/erl \
    warehouses-demo/ot-gateway:dev \
    -boot /app/releases/0.1.0/start_clean \
    -config /probe/sys.config \
    -pa /app/lib/macula-18.3.0/ebin -pa /probe \
    -noshell -run probe check "$station" "$site"
}

echo "== Site A local path (node on station A -> gateway A) =="
probe station-a A

echo
echo "== Site B local path (node on station B -> gateway B) =="
probe station-b B
