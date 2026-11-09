# OT gateway

An `mcl-om` service that translates the controller's REST surface into a small, typed Macula RPC
surface. It dials out to a station and accepts no inbound connection from the mesh or OT network;
`/health` is on a Unix socket.

The release still starts Erlang distribution for its control script, but EPMD and the distribution
listener are bound to loopback (`ERL_EPMD_ADDRESS=127.0.0.1` and
`-kernel inet_dist_use_interface {127,0,0,1}`). No TCP port listens on `mesh_net` or `ot_net`.

This slice exposes five capabilities:

| Capability | Auth | Handler |
|---|---|---|
| `ot/list_freezers` | `open` | `GET /api/freezers` on the controller |
| `ot/set_freezer_target` | `{callers, {nodes, [OperatorNodeId]}}` | `POST /api/freezers/:id/target` |
| `ot/start_freezer_defrost` | `{callers, {nodes, [OperatorNodeId]}}` | `POST /api/freezers/:id/defrost` |
| `ot/stop_freezer_defrost` | `{callers, {nodes, [OperatorNodeId]}}` | `POST /api/freezers/:id/stop` |
| `ot/list_freezer_commands` | `{callers, {nodes, [OperatorNodeId]}}` | the gateway's own audit store |

Every capability is `confidential => required` and the service enables `kem_advertise`, so a caller's
payload is sealed to the gateway's ML-KEM key and the station relays ciphertext.

Writes carry a `command_id` (at least 8 bytes; the dashboard sends 32 hex characters) and a
`requested_at_ms`. `ot_command_guard` remembers accepted ids for two minutes and refuses a duplicate
as `command_replayed` or a timestamp outside the window as `command_expired`. `ot_gateway_audit`
records the wire-verified caller, action, freezer, command id, and result; the last 50 entries are
served by `ot/list_freezer_commands`.

The gateway calls the controller with its own `GATEWAY_USER` / `GATEWAY_PASSWORD` basic credential.
It does not use the legacy `admin/admin` account.

## Configuration

| Variable | Meaning |
|---|---|
| `MCL_REALM` | 64-hex realm tag, read from `/mesh/realm.json` by the entrypoint |
| `MCL_REALM_KEY` | the realm's public signing key, read from `/mesh/realm.json` |
| `MACULA_STATION_SEEDS` | station seeds, default `station:4433` |
| `MACULA_STATION_NODE_IDS` | the station's pinned node id, read from `/mesh/realm.json` |
| `CONTROLLER_URL` | the controller REST base, default `http://freezer-controller:8080` |
| `GATEWAY_USER` / `GATEWAY_PASSWORD` | the controller account used for writes |
| `MESH_OPERATOR_NODE_ID_PATH` | file the entrypoint waits for, default `/mesh/operator-node-id` |
| `OPERATOR_NODE_IDS` | comma-separated operator node ids; normally set by the entrypoint from the file |
| `MCL_SERVICE_NAME` | claim label, default `mcl-ot-gateway` |
| `MCL_BOX` | claim label, default `ot-lab` |

The service identity key is generated on first boot at `/etc/mcl/secrets/identity.key` and persists
on the `gateway_secrets` volume. The `entrypoint.sh` waits for `/mesh/realm.json` (written by the
realm fixture) and `/mesh/operator-node-id` (written by the dashboard's MeshClient), exports the
realm values and `OPERATOR_NODE_IDS`, then starts the release.

Without an operator id the gateway advertises no write capabilities; the read path still serves. The
operator list is read once at boot, so restart the gateway after the dashboard's operator identity
changes (for example after wiping the `/data` volume).

## Build

```bash
docker buildx build --load -t ot-demo/ot-gateway:dev -f Containerfile .
```

The build uses the Macula CI OTP 28.4.3 builder with Rust and the PQ runtime image, so the Macula
NIFs and the `mldsa87` primitive are present. It is normally built by the Compose stack.

## Health

```bash
docker compose -f ../../deploy/compose.yml exec -T ot-gateway \
  curl -sS --unix-socket /run/mcl/health.sock http://localhost/health | jq .
```

A healthy path shows `claim.state: issued` and `provider_grants` containing all five procedures:
`ot/list_freezers`, `ot/set_freezer_target`, `ot/start_freezer_defrost`, `ot/stop_freezer_defrost`,
and `ot/list_freezer_commands`.

The only listening TCP sockets are on `127.0.0.1` and `::1` (EPMD and the distribution port used by
the release control script). There is no listener on `mesh_net` or `ot_net`. The outbound Macula
station link uses an ephemeral local UDP socket as the client side of its QUIC connection; it is not
a service listener.
