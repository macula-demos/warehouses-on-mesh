# Admin UI

Phoenix LiveView dashboard for the OT lab. The same freezer view has two transports:

- **Legacy:** the local Phoenix app calls the controller's exposed REST API through the
  `legacy-edge` port forward, using the shared `admin/admin` account for writes.
- **Mesh:** the local Phoenix app is a Macula citizen. `AdminUi.MeshClient` connects outbound to the
  station, resolves the gateway's typed capabilities, and calls them directly. Reads are open;
  writes are authorized by the operator's node identity, which lives in this app. The browser still
  talks only to localhost and never holds a key.

`MeshClient` writes its operator node id to `/mesh/operator-node-id`; the gateway entrypoint reads
that file at boot and advertises its write procedures only to that node. A second identity at
`/data/stranger.key` exists only for the **Try as stranger** probe: the gateway must refuse it. The
**Replay last command** probe re-sends the previous command id and expects `command_replayed`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `LEGACY_EDGE_URL` | `http://localhost:8080` | The exposed controller edge |
| `MESH_CONFIG_PATH` | `/mesh/realm.json` | Realm tag, realm public key, station node id |
| `MESH_IDENTITY_PATH` | `/data/operator.key` | The operator's node identity (generated on first use) |
| `MESH_STRANGER_IDENTITY_PATH` | `/data/stranger.key` | A second identity used only by the refusal probe |
| `MESH_OPERATOR_NODE_ID_PATH` | `/mesh/operator-node-id` | Where the app publishes its operator node id for the gateway |
| `MESH_STATION_SEEDS` | `station:4433` | Station seed |

The app links the `macula` Erlang SDK. The Docker build installs Rust and compiles the Macula NIFs;
the runtime image must match the builder's glibc/OpenSSL (trixie). This is why the image build is
heavier than the controller's.

## Local development

```bash
mix deps.get
LEGACY_EDGE_URL=http://localhost:8080 mix phx.server
```

Open <http://localhost:4000>. The Mesh mode needs a running station and gateway and a
`/mesh/realm.json`; without them the Mesh button stays disabled and the client retries in the
background.

The app is normally run by the Compose stack; see the repository root README for the full demo.
