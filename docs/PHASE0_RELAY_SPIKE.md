# Phase 0 — relay spike: decision and evidence

Status: **decided: two federated stations.** The local lab can do it, so the
fallback to one shared station is not used.

The spike is reproducible with `scripts/phase0-spike.sh`; it uses only station
containers plus a throwaway Erlang provider/caller module under
`deploy/phase0/`. No demo app code existed when this decision was made.

## What was verified, against the image actually used

Part 1's `deploy/compose.yml` uses `ghcr.io/macula-io/macula-station:0.13.3`.
The keys below were checked in that image's config loader
(`macula_station_config.erl`) and in the deployment guide, not assumed:

- `outbound_peers` is the station-to-station linking mechanism. Each entry is
  `{ "host", "port", "expected_node_id" }`. A peer without `expected_node_id`
  is carried but **cannot dial** — the 11.x peering layer refuses an unpinned
  client dial.
- `bootstrap` keeps the part 1 discoverer
  (`macula_station_via_seed_dial`) with `min_peers: 0`. A station boots as an
  island, then its `outbound_peers` links form the pair.
- `admin` stays on `127.0.0.1:8443` inside each station container; `/status`
  reports the station `node_id`.
- `bind` is a concrete address on the Compose network
  (`172.28.0.10` / `172.28.0.11`), not `0.0.0.0`, so the `station_endpoint`
  record carries a dialable host.

Because a pinned `outbound_peers` entry needs the peer's node id, and a fresh
station mints that id on first boot, the script does this once:

1. Boot both stations as islands with `outbound_peers: []`.
2. Read each `/status` `node_id`.
3. Write each station's config with the other's id in `outbound_peers`.
4. Recreate both stations. The data volumes keep the identities, so the ids
   survive the recreation.
5. Wait until both `/status` snapshots report `swim.members >= 1`.

Observed on the spike run: `Peer links: A=1 B=1`.

## The call that crossed the relay

The provider (an Erlang node) dialed **station B**, minted an `ot`-style
org/delegation chain, and advertised `phase0/echo_v1` sealed
(`confidential => required`). The caller dialed **station A**. The caller's
own link list was printed before and after:

```text
links before calls: {ok,[#{connected => true, host => <<"station-a">>, ...}]}
links after relay:  {ok,[#{connected => true, host => <<"station-a">>, ...}]}
```

Only station A. The call was then sent to station A with the provider on
station B as its target:

```erlang
macula:call_station(Pool, <<"quic://station-a:4433">>, ProviderOnB,
                    Realm, <<"phase0/echo_v1">>, Payload, 8000,
                    #{expected_node_id => StationA, report => true,
                      confidential => required})
```

Result:

```erlang
{ok, #{{text,<<"echo">>} => #{... {text,<<"via">>} => <<"station-a-forwarded">>}},
    #{provider => <<... provider on B ...>>,
      sealed => 1,
      seal_key_id => <<...>>}}
```

`sealed => 1` is the gate for the sealed path. The relay saw the sealed
request.

## Evidence that station A forwarded it

- The caller held no link to station B. A direct dial to B was not made, and
  the call was addressed to station A.
- Station A's `/telemetry/frames` counter for `frames.call.forward_rtt` had
  three samples after the calls (`below_25ms: 3`), and station B's had three.
  `forward_rtt` is the station's own histogram for a forwarded CALL's round
  trip through its advertiser. A station that only answered locally would not
  produce it.
- Station A's `/health` `call_bounds.forwards_in_flight` was non-zero while a
  forwarded call was outstanding and returned to zero after the reply; the
  call-bounds counters stayed at zero (no drops).

## Honest boundary found during the spike

The SDK's direct-dial path (plain `macula:call`) resolves a provider's
`station_endpoint` and builds `quic://[<host>]:<port>`. In macula 18.3.0 that
bracketed form is rejected by `macula_station_link:parse_seed/1` when the host
is an IPv4 literal, so a cross-station direct dial fails with
`{dial_refused, unusable_seed}`. The spike showed this explicitly
(`DIRECT ... {error,{dial_refused,unusable_seed}}`).

This is not a station federation problem. It is why the demo app will route a
site's calls through **that site's own station** with `call_station` and a
provider target, instead of relying on the SDK's cross-station direct dial.
That is the stronger claim anyway: the CALL is forwarded by station A to
station B, not handed to the caller as a direct dial to B.

The lab realm fixture will therefore advertise its boot-claim procedure on
both stations, so each gateway's boot claim is served by its local station
and never needs a cross-station direct dial. That extension is recorded in
Phase 2.

## What this does not yet prove

- The station's wire logs are not a packet capture. Phase 3 will capture the
  mesh traffic while a cross-site read is in flight and show that the payload
  plaintext does not appear in it. Phase 0 proves `sealed: 1` and the relay
  path, not the absence of plaintext in a capture.
- The spike's provider is a bare Erlang node, not the OT gateway. The gateway
  keeps part 1's exact sealing and policy code; Phase 1-4 exercise it.
- The spike does not prove a real `macula-realm`; the lab fixture remains a
  fixture.
