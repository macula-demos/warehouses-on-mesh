# What this slice proves — and what it does not

Status: **built.** Two sites, two gateways, two federated stations, and one dashboard at site A.
The Phase 0 decision was **two federated stations**, not one shared relay; the evidence and
mechanism are in [PHASE0_RELAY_SPIKE.md](PHASE0_RELAY_SPIKE.md). Every row below is marked
built/not-built against a gate that was run in this lab.

## Acceptance gates

| Gate | Status | Evidence |
|---|---|---|
| **G1** cross-site read works with no inbound port at site B | pass | The dashboard's site B view lists `FZ-B1..B4`; `./scripts/local-path-probe.sh` checks both local paths; `./scripts/posture-check.sh` finds no host listener for either controller or gateway. |
| **G2** cross-site call report shows `sealed: 1`; relay logs show ciphertext only | pass | The site B read/write reports say `sealed: 1`; `./scripts/capture-relay.sh` finds the marker and freezer payload in neither the pcap nor either station's logs; `./scripts/clear-call-probe.sh` gets `sealed_required`. |
| **G3** authorized write lands on site B; both audits correct | pass | `./scripts/phase4-gate.sh` writes `FZ-B1`, returns `ok sealed=1`, shows the operator in gateway B's audit, and shows only `gateway` in both controller audits. |
| **G4** stranger → `unauthorized`; replay → `command_replayed` | pass | `./scripts/phase4-gate.sh` asserts both; the dashboard's two refusal buttons show the same results. |
| **G5** no open TCP listener anywhere except the documented loopback/outbound exceptions | pass | `./scripts/posture-check.sh`: only the dashboard's `4000` is published; both gateways have loopback-only TCP control listeners; both controllers are filtered from the relay network. |
| **G6** this document is honest: nothing claimed that is not passing a gate | pass | Every row above is marked built/not-built, and the boundaries section names the lab-grade limits. |

## Promise vs. what is built

| # | Claim | Status | What this slice shows | What it does not show |
|---|-------|--------|----------------------|----------------------|
| 1 | A site A operator reads site B freezers through the relay with no inbound port at B. | **built** | The dashboard at A selects site B and lists four `FZ-B1..B4` freezers. The call is sent to station A with gateway B as its target; station A forwards it to station B, which forwards it to gateway B. `./scripts/local-path-probe.sh` proves both local paths independently. `./scripts/posture-check.sh` shows no host listener for either controller or gateway. | A public station fleet or a real site-to-site WAN. Both stations are local Docker containers on one host. |
| 2 | The cross-site call is sealed end to end; the station relays ciphertext. | **built** | The site B read report is `sealed: 1` with the site B provider and a seal key id. `./scripts/capture-relay.sh` sends a marked call through station A, captures its QUIC traffic, and finds neither the marker nor the freezer payload in the pcap or either station's logs. `./scripts/clear-call-probe.sh` sends the same read in the clear; the gateway refuses it `sealed_required`. | That every possible deployment enforces sealing. Sealing protects the payload, not routing metadata; the station still sees the realm, procedure, caller, and the sealed blob. |
| 3 | An authorized write crosses the relay and lands on site B; the gateway audit records the verified caller and the controller audit records only the gateway. | **built** | The operator at A changes `FZ-B1`; the write returns `sealed: 1`, the site B gateway audit row names the wire-verified operator node, and the controller B audit shows only `gateway`. `./scripts/phase4-gate.sh` asserts the write, the audit users, and the result. | That the controller can see the operator. It cannot; that is the point. The controller audit is read from the site network by `./scripts/show-audits.sh`, not by the dashboard. |
| 4 | A stranger node's write is refused `unauthorized` before the handler. | **built** | A second node identity on station A calls the site B write capability through the relay; the gateway refuses it with `unauthorized`. `./scripts/phase4-gate.sh` asserts it, and the dashboard's **Try as stranger on site B** button shows the same refusal. | Dynamic enrollment or a realm role. The operator list is boot-time state. The refusal happens before the handler, so it produces no gateway audit row. |
| 5 | A replayed command id is refused `command_replayed`. | **built** | The dashboard's replay probe and `./scripts/phase4-gate.sh` re-send the same command id; the gateway refuses it as `command_replayed` and adds an audit row with that result. | A durable dedupe store. The guard is in memory with a two-minute TTL; a replay after a gateway restart is not refused. |
| 6 | Neither gateway nor controller has a TCP listener reachable from outside its site. | **built** | `./scripts/posture-check.sh` finds only the dashboard's published 4000; both gateways have no non-loopback TCP listener; both controllers are attached only to their site network and are filtered from the relay network; the stations' TCP control ports are loopback only. | That the stations are private. The station is the relay and accepts `4433/udp` from the mesh; that is its job. The browser UI's 4000 is published on purpose. |
| 7 | Two federated stations carry the call; the application resolves both gateways' advertisements. | **built** | The two stations link with pinned `outbound_peers`; station A's `forward_rtt` telemetry records the forwarded site B calls. The dashboard's provider table lists two providers, one per site, both advertising the same `ot/list_freezers` procedure; it picks by provider node id. | A production federation or public discovery. The pins are explicit lab config; the stations are on one Docker network. |

## What the mesh path proves, concretely

Read path:

- The dashboard dials station A only. It never dials station B. `MeshClient` calls
  `macula:call_station(pool, "quic://station-a:4433", provider_b, ...)`, so the CALL is sent to
  station A with gateway B as the target.
- Station A's remote-advertisement registry holds gateway B's signed advertisement (gossiped from
  station B), so station A forwards the CALL over its station-to-station link. Station B forwards
  it to gateway B. The caller's link list contains station A, not station B.
- The call report says `sealed: 1`, names gateway B as the provider, and carries a seal key id.
  The station has no gateway KEM private key.
- `./scripts/capture-relay.sh` runs a marked site B read through station A. The marker and the
  freezer payload are absent from the pcap and from both stations' logs. A clear call to the same
  capability is refused `sealed_required`.

Write path:

- The dashboard generates the operator identity at `/data/operator.key`, writes its node id to
  `/mesh/operator-node-id`, and both gateways' entrypoints export the same allowlist. Neither
  gateway advertises a write capability without it.
- The operator at A sends a site B write to station A with gateway B as the target. Station A
  forwards it; gateway B checks the wire-verified caller against its advertisement's
  `{callers, {nodes, [OperatorNodeId]}}` policy, runs the command guard, calls controller B with
  its own `gateway` account, and records the operator node, action, freezer, command id, and
  result.
- The stranger is a second identity on station A. The same forwarded call is refused
  `unauthorized` before the handler. The replay probe re-sends the previous command id and is
  refused `command_replayed`.
- Controller B's own audit records only `gateway`; it never sees the operator node or the
  browser.

Provider resolution:

- Both gateways advertise the same `ot/*` names in the same realm. The dashboard's background
  refresh calls `macula_direct_dial.providers/4` on station A, dedupes by provider node id, and
  shows both rows with their serving stations. The site B row's serving station is station B.
- This is the federation beat: two providers is expected, not a duplicate. The dashboard picks a
  provider by node id and passes that target to `call_station`.

## What is still missing

1. **A real public federation.** The stations are local containers with pinned peers on one
   Docker network. A production deployment needs public station addresses, real discovery, and
   the operational concerns of a fleet.
2. **A real `macula-realm`.** The fixture mints the realm/org keys, publishes the D25 chain, and
   answers both gateways' boot claims. It is a lab stand-in, not membership, roles, or operator
   approval.
3. **Durable command state.** The guard is an in-memory map with a two-minute TTL. A durable,
   signed command log would survive a gateway restart and give an auditor the full trail.
4. **Signed reading history.** Publish each reading as a signed fact and provide an export an
   auditor can verify without Macula.
5. **A real protocol adapter.** The controllers are HTTP/REST simulators. Modbus, BACnet, OPC UA,
   or a vendor API is part 3's subject.
6. **Multi-operator approval and dynamic revocation.** The operator allowlist is a boot-time
   file shared by both gateways; part 5's subject.
7. **Dynamic operator enrollment.** Changing the operator identity requires rewriting
   `/mesh/operator-node-id` and restarting both gateways so their entrypoints re-read it.

## Explicit non-goals (not built, not claimed)

- **One shared station.** The fallback was not used. The lab runs two federated stations and
  the site B CALL is forwarded A → B.
- **A real `macula-realm` membership.** The lab realm fixture stands in for membership, roles,
  and operator approval.
- **Durable command state or signed history.** The command guard is in memory; part 4 owns the
  signed history.
- **Real OT protocols.** The controllers are HTTP/REST simulators; part 3 owns Modbus/BACnet/OPC
  UA.
- **Multi-operator approval.** Part 5's subject.
- **An attacker container and a legacy edge.** Deliberately absent; part 1 tells that story.
- **A public multi-host station fleet.** Both stations are local containers on one host.
- **A production identity or enrollment system.** The operator allowlist is a boot-time file.

## Honest boundaries

- **"No inbound port" is not "nothing can call in."** Each gateway still receives commands over
  its outbound station link. What guards them is the procedure policy and the command guard, not
  a firewall. The stations are the public relays and accept `4433/udp`.
- **The stations are local.** Two `macula-station:0.13.3` containers on one host, on an internal
  Docker network with static addresses. The station-to-station link is an outbound QUIC link
  pinned by `expected_node_id`; the lab reads each node id on first boot and recreates the
  stations with mutual `outbound_peers`.
- **The SDK's cross-station direct dial is avoided.** In macula 18.3.0, a resolved IPv4
  `station_endpoint` becomes `quic://[<ipv4>]:<port>`, which the seed parser rejects, so a plain
  `macula:call` across stations fails `unusable_seed`. The dashboard uses
  `macula:call_station` to its own station with the other site's provider as the target. That is
  the stronger path for this demo; it is also why the app does not rely on the SDK's direct dial.
- **The realm fixture is a fixture.** It pre-publishes the D25 chain and answers boot claims from
  the verified caller. Its delegation has a TTL; after a long-running lab the gateways' grants
  can show `expiring` and `/health` can be `degraded` while calls still work. A long demo should
  start from `./scripts/mesh-demo.sh`; a wedged fixture is restarted as in part 1. This is part 1's
  fixture behavior, not a new federation claim.
- **The operator allowlist is boot-time state.** Both gateways read the same
  `/mesh/operator-node-id` once at boot. If the dashboard's identity changes, restart both
  gateways. There is no dynamic enrollment or revocation.
- **The command guard is in memory.** It stops a duplicate within two minutes in one gateway
  process. A gateway restart or a longer delay clears the memo; a durable command log is part 4's
  subject.
- **Sealing protects the payload, not routing metadata.** The station still sees the realm,
  procedure, caller, and the sealed bytes. The controller link is plain HTTP on the site network.
- **The wire capture is TLS ciphertext.** The pcap check shows no payload on the wire; the
  application-level seal is proven by the call report (`sealed: 1`), the gateway's
  `confidential => required`, and the `sealed_required` refusal of a clear call. The capture is
  supporting evidence, not the whole proof.
- **The controller audit is a side-channel.** The dashboard has no route to either controller
  (that is the posture claim). `./scripts/show-audits.sh` reads each controller's own audit from
  its site network and shows only `gateway` rows.
- **Both gateways advertise the same procedure names.** The dashboard handles the duplicate by
  provider node id. A real deployment may pin a provider or use a site-scoped name; this lab
  deliberately leaves the names identical to make the resolution beat visible.
- **The BEAM control ports are loopback.** The gateway's EPMD and distribution listen on
  `127.0.0.1`/`::1`; the station's admin and distribution do too. The controller and dashboard
  releases run with `RELEASE_DISTRIBUTION=none`, so they have no distribution listener. The
  remaining listeners are the controller's `8080` on its internal site network, the dashboard's
  published `4000`, and the station's `4433/udp` mesh listener.
- **The gateway's QUIC client binds a UDP socket.** It is an outbound client socket, not a TCP
  listener; a UDP scan may show a port. Part 1 documents the same boundary.

## What would make the demo stronger

- Two stations on two hosts, reached by DNS names, with the same pinned `outbound_peers` and no
  shared Docker network.
- A real `macula-realm` membership and an operator-approved role instead of the fixture and the
  boot-time allowlist.
- A durable, signed command log and a signed reading history an auditor verifies without Macula.
- A real Modbus/BACnet/OPC UA adapter behind the same typed gateway (part 3).
- Multi-operator approval and dynamic revocation (part 5).
- A hardware gateway on the site network instead of a container.

These are deliberately outside this slice.
