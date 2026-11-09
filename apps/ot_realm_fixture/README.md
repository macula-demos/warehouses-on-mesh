# OT realm fixture (lab only)

**This is not `macula-realm`.** It is a self-contained stand-in that makes the lab runnable without
a realm service, an operator approval flow, or a public fleet.

At boot it:

1. Reads the station node id from `/mesh/station-node-id`.
2. Loads or generates its realm key, `ot` org key, `io.macula` org key, and node identity in
   `/data`.
3. Connects to the station with the realm key pinned as `realm_trust`.
4. Publishes the signed `org_directory` records for `io.macula` and `ot`, and its own `io.macula`
   `procedure_delegation`.
5. Advertises
   `io.macula/_realm/_realm/identity/request_provider_authorization_v1` with `auth => open`.
6. Writes `/mesh/realm.json` with the realm tag, realm public key, and station node id.

When the gateway claims, the handler reads the wire-authenticated caller, signs an `ot`
`procedure_delegation` for that node id with the `ot` org key, publishes it, and returns
`{status: issued}`. The gateway's advertise path then resolves the chain.

The realm tag is `sha256("io.macula.otlab")`, so it is stable across restarts.

## Why a fixture

The live `mcl-om` tests already show the pattern: a client can publish its own D25
`org_directory` and `procedure_delegation` to a realm-agnostic station. The fixture packages that
pattern for the lab. A real deployment uses `macula-realm` membership, roles, and an operator's
approval instead.

## Files

| Path | Contents |
|---|---|
| `/data/realm.key` | realm signing key (private, persisted) |
| `/data/ot_org.key` | `ot` org signing key |
| `/data/io_org.key` | `io.macula` org signing key |
| `/data/identity.key` | fixture node identity |
| `/mesh/station-node-id` | station node id, written by `scripts/mesh-demo.sh` |
| `/mesh/realm.json` | public realm values for the gateway and dashboard |

## Build

```bash
docker buildx build --load -t ot-demo/ot-realm-fixture:dev -f Containerfile .
```

The build uses the Macula CI OTP 28.4.3 builder with Rust and the PQ runtime image. It is normally
built by the Compose stack.
