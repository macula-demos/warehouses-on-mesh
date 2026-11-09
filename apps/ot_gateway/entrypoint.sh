#!/bin/sh
set -eu

REALM_FILE="${MESH_CONFIG_PATH:-/mesh/realm.json}"

i=0
while [ ! -s "$REALM_FILE" ]; do
  i=$((i + 1))
  if [ "$i" -ge 120 ]; then
    echo "ot-gateway: $REALM_FILE did not appear; is the realm fixture running?" >&2
    exit 1
  fi
  sleep 1
done

export MCL_REALM="$(jq -r .realm "$REALM_FILE")"
export MCL_REALM_KEY="$(jq -r .realm_key "$REALM_FILE")"
export MACULA_STATION_NODE_IDS="$(jq -r .station_node_id "$REALM_FILE")"
export MACULA_STATION_SEEDS="${MACULA_STATION_SEEDS:-station:4433}"
export MCL_SERVICE_NAME="${MCL_SERVICE_NAME:-mcl-ot-gateway}"
export MCL_BOX="${MCL_BOX:-ot-lab}"

OPERATOR_FILE="${MESH_OPERATOR_NODE_ID_PATH:-/mesh/operator-node-id}"
i=0
while [ ! -s "$OPERATOR_FILE" ]; do
  i=$((i + 1))
  if [ "$i" -ge 120 ]; then
    echo "ot-gateway: $OPERATOR_FILE did not appear; is the admin UI running?" >&2
    exit 1
  fi
  sleep 1
done
export OPERATOR_NODE_IDS="$(cat "$OPERATOR_FILE")"

exec /app/bin/ot_gateway foreground
