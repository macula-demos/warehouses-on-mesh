# warehouses-on-mesh

Part 2 of the macula-demos OT series: the same cold-chain company opens a second warehouse,
and the mesh is what connects them — two sites, two gateways, a relay in between, and no
inbound port anywhere.

**Status: planned.** This repository is initiated but nothing is built yet. The build spec is
in [CLAUDE.md](CLAUDE.md).

## The one claim this demo makes

A person at site A can read and command the freezers at site B through the mesh — across a
station relay — while:

- neither site has an inbound path (every box dials out),
- the calls are sealed end to end (the station relays ciphertext),
- the commands are authorized per caller, refused for strangers, and refused on replay.

Part 1 ([freezers-on-mesh](https://github.com/macula-demos/freezers-on-mesh)) proved all of
that for a *single* site and a *single* local station. This repo exists to prove the part the
series name implies: **the mesh itself** — federation, station-to-station relay, and
multi-provider capability resolution.

## Story

Acme Cold Storage runs the part 1 retrofit at warehouse A, then opens warehouse B with the
same controller and the same gateway. The quality manager at A needs to see and command B's
freezers without any port forward at B. Both gateways dial out to the relay; the dashboard
resolves both providers and picks by site.

## Planned topology

```text
   site A (warehouse A)              relay                  site B (warehouse B)
 ┌──────────────────────┐     ┌────────────────┐        ┌──────────────────────┐
 │  admin laptop        │     │                │        │  gateway B           │
 │  (Phoenix UI)        ├─QUIC►  station A     │◄─QUIC──┤  (mcl-om, no TCP    │
 │  gateway A           │     │   ◄─federated─► │        │   listener)         │
 │  (mcl-om)            ├─QUIC►  station B     │◄─QUIC──┤  controller B        │
 │  controller A        │     └────────────────┘        │  (freezers FZ-B*)    │
 │  (freezers FZ-A*)    │                               └──────────────────────┘
 └──────────────────────┘
```

Whether the relay is one station both sites dial, or two federated stations, is phase 0 of the
build — see [CLAUDE.md](CLAUDE.md). The claim requires the call to cross a station; the
two-station version proves the strongest form of it.

## What gets reused

Part 1's skeleton is the starting point: the freezer controller simulator, the `mcl-om`
gateway with its `ot/*` capabilities, operator allowlist, command guard and audit, the realm
fixture, and the Phoenix dashboard with its mesh transport. The gateway is expected to need
**no code changes at all**; the new work is the two-site topology, the station config(s), the
dashboard's site picker, and the scripts that prove the relay.

## Repository layout (planned)

```text
apps/
  warehouse_controller/   Freezer controller sim, two instances (FZ-A* / FZ-B*)
  ot_gateway/             mcl-om gateway, two instances, one per site
  ot_realm_fixture/       Lab realm chain + claim responder (shared by both gateways)
  admin_ui/               Phoenix LiveView dashboard, site picker, both audits
deploy/
  compose.yml             Two-site topology, no inbound ports
  station-a/ station-b/   Station configs (one or two stations, per phase 0)
docs/
  DEMO_SCRIPT.md          Video run sheet (planned beats)
  WHAT_THIS_PROVES.md     Claim-by-claim boundaries
scripts/                  mesh-demo.sh, probes, reset
assets/                   demo.mp4, demo-poster.png (made when the video is asked for)
```

## The series

| # | Repo | One claim |
|---|------|-----------|
| 1 | [freezers-on-mesh](https://github.com/macula-demos/freezers-on-mesh) | A retrofit removes the inbound path and moves authority to the mesh |
| 2 | **warehouses-on-mesh** | Federation: sealed cross-site calls with no inbound ports anywhere |
| 3 | [pumps-on-mesh](https://github.com/macula-demos/pumps-on-mesh) | The same gateway pattern behind a real Modbus TCP controller |
| 4 | [verifiable-coldchain](https://github.com/macula-demos/verifiable-coldchain) | Signed reading history an auditor verifies without Macula |
| 5 | [two-person-rule](https://github.com/macula-demos/two-person-rule) | Dual control with dynamic enrollment and revocation |

## License

Apache-2.0. See [LICENSE](LICENSE).
