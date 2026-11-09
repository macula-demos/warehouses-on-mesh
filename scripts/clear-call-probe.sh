#!/usr/bin/env bash
# A clear call to the same read capability must be refused by the gateway.
# The station forwards it; the gateway enforces `confidential => required`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE="$ROOT/deploy/probe"
STATE="$ROOT/deploy/generated"

(cd "$CODE" && erlc probe.erl)

OUT="$(docker run --rm --pids-limit -1 \
  --network warehouses-lab_mesh_net \
  -v "$STATE:/mesh:ro" \
  -v "$CODE:/probe:ro" \
  --entrypoint /app/erts-16.3.1/bin/erl \
  warehouses-demo/ot-gateway:dev \
  -boot /app/releases/0.1.0/start_clean \
  -config /probe/sys.config \
  -pa /app/lib/macula-18.3.0/ebin -pa /probe \
  -noshell -run probe clear station-a A)"

printf '%s\n' "$OUT"
printf '%s\n' "$OUT" | grep -q 'result=sealed_required'
echo "Clear call refused: the read capability requires sealing."
