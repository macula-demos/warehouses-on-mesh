# What this demo will prove — and what it will not

Status: **planned; Phase 0 decided.** The relay spike proved two federated stations and a
sealed CALL forwarded from station A to station B — see
[PHASE0_RELAY_SPIKE.md](PHASE0_RELAY_SPIKE.md). No demo app code exists yet. Every row below
must be updated to built/not-built as phases land, in the style of `freezers-on-mesh` (part 1).

| # | Claim | Status |
|---|-------|--------|
| 1 | A site A operator reads site B freezers through the relay with no inbound port at B. | planned |
| 2 | The cross-site call is sealed end to end; the station relays ciphertext. | planned |
| 3 | An authorized write crosses the relay and lands on site B; both audits record the verified caller. | planned |
| 4 | A stranger node's write is refused `unauthorized` before the handler. | planned |
| 5 | A replayed command id is refused `command_replayed`. | planned |
| 6 | Neither gateway nor controller has a TCP listener reachable from outside its site. | planned |

## Explicit non-goals (not built, not claimed)

- Station-to-station federation, if phase 0 lands on one shared station — then the claim is
  cross-site via a shared relay, stated as such.
- A real `macula-realm` membership; the lab realm fixture stands in (as in part 1).
- Durable command state or signed history (part 4's subject).
- Real OT protocols (part 3's subject).
- Multi-operator approval (part 5's subject).
