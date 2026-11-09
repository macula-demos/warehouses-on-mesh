# CLAUDE.md — build spec for warehouses-on-mesh

Part 2 of the macula-demos OT series. Part 1 is `freezers-on-mesh` (sibling repo,
`../freezers-on-mesh` locally, `macula-demos/freezers-on-mesh` on GitHub) — read its README,
`docs/WHAT_THIS_PROVES.md`, and the code of all four apps **before starting**. This repo
starts as a copy of that lab's working patterns; the job is to split it into two sites and
make a call cross the relay, not to invent new security machinery.

## The one claim

A person at site A reads and commands site B's freezers through the mesh, with no inbound
port at either site, sealed calls, per-caller authorization, and replay refusal. The station
relay must see only ciphertext.

## Ground rules

1. Copy part 1's components verbatim wherever possible. The gateway must not change unless a
   change is required by the claim; the claim as written requires none.
2. Two gateway instances and two controller instances, same code, different env:
   - site id `A`/`B`, freezer ids `FZ-A1..A4` / `FZ-B1..B4`
   - both gateways advertise the SAME `ot/*` procedure names (both claim the `ot` org) —
     the dashboard resolves BOTH providers and picks by node id. Multi-provider resolution
     is a demo beat, not a bug.
3. One realm fixture serving both gateways' boot claims (extend it only if it cannot already
   answer two claimant nodes).
4. Keep the same procedure policies as part 1: reads open, writes
   `{callers, {nodes, [OperatorNodeId]}}`, command ids with replay + expiry guard, gateway
   audit, controller audit showing only the `gateway` account.
5. No attacker container, no legacy edge in this lab. The retrofit is assumed done at both
   sites; part 1 tells that story. The drama here is the relay.
6. No real protocols (that is part 3). The controller stays HTTP/REST on its site net.
7. Honesty rules from part 1 carry over: the realm fixture is a lab stand-in; the operator
   allowlist is boot-time state; the command guard is in memory; sealing protects payload,
   not routing metadata. Every row in `docs/WHAT_THIS_PROVES.md` must be marked
   built/not-built, never assumed.

## Phases

### Phase 0 — relay spike (do this FIRST, timebox to half a day)

Goal: prove a call crosses a station locally, and record the exact mechanism.

- Bring up TWO local macula stations and link them (federation), per the macula station
  docs. Verify the exact config keys/linking mechanism against the station image used by
  part 1's `deploy/compose.yml` before trusting any assumption here.
- Prove: a node dialing station A can call a procedure served by a node dialing station B.
  Capture the call report (path, sealed flag) and what each station's logs show.
- Decide and RECORD in `docs/WHAT_THIS_PROVES.md`: two federated stations (strongest claim)
  vs one shared station both sites dial (weaker: proves cross-site via a shared relay, not
  station-to-station). If two-station federation is not workable in the local lab, fall back
  to one station and state it honestly. **Do not build app code before this decision.**

### Phase 1 — baseline lab

Bring up part 1's lab (station, realm fixture, gateway, controller, dashboard) with no
attacker and no legacy edge, as the base to split. Gate: part 1's read/write/replay/stranger
beats still work.

### Phase 2 — split into two sites

Two controllers, two gateways, site-scoped env, stations per the phase 0 decision, dashboard
shows both sites. Gate: the site A local path and site B local path both work; both gateways'
advertisements are visible to the dashboard as two providers.

### Phase 3 — cross-site read

Dashboard at A lists site B freezers through the relay. Gate: the call report shows
`sealed: 1`; the station's own logs show no plaintext payload.

### Phase 4 — cross-site write + refusals

Operator at A commands a site B freezer: it lands, gateway B's audit row shows the
wire-verified operator node, controller B's audit shows only `gateway`. A stranger node's
write → `unauthorized` before the handler. A replayed command id → `command_replayed`.

### Phase 5 — posture checks + scripts

Port checks adapted from part 1 for two sites: no TCP listener on either gateway or
controller reachable from any simulated outside net; both gateways dial out; loopback-only
control ports are the documented exception.

### Phase 6 — docs

Finish `docs/WHAT_THIS_PROVES.md` (mark every row built/not-built, keep part 1's honest
boundary style) and `docs/DEMO_SCRIPT.md` as a run sheet for the ~90-second video.

## Acceptance gates (all must pass before this repo says "built")

- **G1** cross-site read works with no inbound port at site B.
- **G2** cross-site call report shows `sealed: 1`; relay logs show ciphertext only.
- **G3** authorized write lands on site B; both audits correct.
- **G4** stranger → `unauthorized`; replay → `command_replayed`.
- **G5** no open TCP listener anywhere except the documented loopback/outbound exceptions.
- **G6** `WHAT_THIS_PROVES.md` is honest: nothing claimed that is not passing a gate.

## Video notes (the video is asked for separately, but design for it now)

~90 seconds, silent with captions, one poster frame, same conventions as part 1's
`assets/demo.mp4`. Beats: (1) two sites + relay topology, everything dials out; (2) manager
at A picks site B, live readings arrive, report says sealed; (3) a target change/defrost
lands on site B, audits match; (4) stranger refused, replay refused; (5) posture cards: no
inbound ports, operator node, sealed — the relay carried ciphertext. The dashboard is the
star of every beat; keep it clean and readable at 1080p.

## Do not

- Do not change the gateway security model (procedure policies, command guard, audit) unless
  a phase requires it; the phases above require none.
- Do not add CRUD events, horizontal layer folders, or services/utils/helpers directories;
  follow the structure of part 1's apps.
- Do not touch the four sibling repos.
- Do not claim anything in README or docs that is not passing a gate.
