# Demo script — 90-second run sheet

Status: **built; video not recorded.** This is the run sheet for the silent, captioned ~90 s
walkthrough. The dashboard is the star of every beat.

## Preconditions

- Docker with Compose, about 4 GB free for the two Elixir controllers, two gateways, the
  fixture, and the dashboard.
- Port `4000` free for the dashboard. The lab publishes no other host port.
- First run: `./scripts/mesh-demo.sh` pulls `macula-station:0.13.3`, builds the two controllers,
  the two gateways, the fixture, and the dashboard, then waits for both stations to federate,
  both gateways to claim, and the UI to settle. Later runs reuse the cache.
- Open <http://localhost:4000> at 1920×1080, dark theme. The dashboard opens on **Site A**.
- Wait until the **Providers** table shows **2 providers** (the second advertisement crosses
  the station link; this can take up to 30 s after the gateways start). Then the topology beat
  is ready to record.

## The run sheet

| Time | Beat | What the viewer sees | Caption |
|---|---|---|---|
| 0:00–0:12 | Topology | The two site cards: **Site A · local station** and **Site B · via relay**, with their gateway and station short ids. The centre relay card says `station A ⟷ station B`, **no inbound port**, **ciphertext only**. The provider table below already lists **2 providers**, both advertising `ot/list_freezers`. | Two warehouses. Two federated stations. One relay. Everything dials out. |
| 0:12–0:30 | Cross-site read | Click the **Site B · via relay** card. The freezer grid switches to `FZ-B1 … FZ-B4`; the header says **Site B freezers** and **via relay**; the **Last call** line says **sealed · provider &lt;site B provider&gt; · key …**. The values update live. | The manager at A picks site B. The read is sent to station A; station A forwards it to station B. The report says sealed. |
| 0:30–0:52 | Cross-site write | On `FZ-B1`, click **+50**. The flash says **Gateway accepted FZ-B1 target 50.0°C (sealed)**. The **Gateway B audit** gains a row: the operator's node id, `set_target`, `FZ-B1`, a command id, result `ok`. Cut to a small terminal: `./scripts/show-audits.sh`; controller B's newest row is `user: gateway`, `FZ-B1`, `ok`. | The operator changes a site B freezer through the relay. Gateway B records the verified operator; controller B sees only the gateway account. |
| 0:52–1:10 | Refusals | Click **Replay last command (should be refused)**: flash **Command refused: command_replayed**. The gateway audit gains a second row with the same command id and `command_replayed`. Click **Try as stranger on site B (should be refused)**: flash **Stranger &lt;node-id&gt; on site B refused: unauthorized**. No stranger row appears. | Replay refused. A stranger node refused before the handler. The policy is per caller, not a shared secret. |
| 1:10–1:30 | Posture | Cut to the posture cards: **no inbound port**, **operator node**, **sealed: 1**, **A → B**. Optionally show `./scripts/posture-check.sh`: only the dashboard's `4000` is published; both gateways have no non-loopback TCP listener; both controllers are filtered from the relay network. A final cut shows `./scripts/capture-relay.sh`: **No marker or freezer payload in the relay capture** and **no marker or freezer payload in either station's logs**. | Neither site has an inbound port. The relay carried routing metadata and ciphertext. The gateway alone holds the key. |

## Exact commands used in the run

```bash
# Start the lab once; wait for the dashboard.
./scripts/mesh-demo.sh

# The dashboard: http://localhost:4000
# Beat 1-2: read the site cards and the provider table; click "Site B".
# Beat 3: click +50 on FZ-B1.
./scripts/show-audits.sh          # controller A/B audit; controller B shows gateway only
# Beat 4: click Replay last command, then Try as stranger on site B.
# Beat 5:
./scripts/posture-check.sh
./scripts/capture-relay.sh
```

Optional automated gates, if the video needs a terminal inset:

```bash
./scripts/local-path-probe.sh     # both local paths: four freezers, sealed=1
./scripts/phase4-gate.sh          # write ok, replay refused, stranger refused, audits gateway
```

## Reset between takes

```bash
./scripts/reset.sh
```

The reset goes through each controller's gateway account, so the controller audit stays
`gateway`-only. It does not clear the gateway audits; restart the lab if the audit tables should
start empty:

```bash
docker compose -f deploy/compose.yml down -v
./scripts/mesh-demo.sh
```

## Troubleshooting during a take

- **One site card says "resolving provider…" and the provider table has one row.** The station
  link's advertisement gossip can take up to 30 s after the gateways start. Wait, or restart the
  gateways. The dashboard's background refresh resolves the second provider automatically.
- **The gateway `/health` says `degraded` or the claim is `not_delivered`.** A long-running
  fixture can lapse its delegation TTL (part 1's known fixture behavior). Restart the fixture and
  then the gateways:

  ```bash
  docker compose -f deploy/compose.yml restart ot-realm-fixture
  sleep 5
  docker compose -f deploy/compose.yml up -d --force-recreate --no-deps ot-gateway-a ot-gateway-b
  ```

  The dashboard's `mesh-demo.sh` starts a fresh lab and waits for `claim.state: issued`.
- **A write returns `unauthorized` for the operator.** The dashboard must connect and write
  `/mesh/operator-node-id` before the gateways boot. Open the dashboard, then restart both
  gateways if the operator key changed.
- **Replay returns `command_expired` instead of `command_replayed`.** More than two minutes
  passed between the write and the replay. Do a fresh write and replay immediately.
- **Port 4000 is in use.** Stop the other server or change the published port in
  `deploy/compose.yml`.
- **The station is crash-looping with `no_tiers`.** Its config must keep the single
  `via_seed_dial` discoverer with `min_peers: 0`; `mesh-demo.sh` writes that config.
- **The stations do not federate.** The first boot reads each station's `/status` node id and
  writes it into the other's `outbound_peers`; on a volume wipe, re-run `mesh-demo.sh` from the
  start. Check `docker compose -f deploy/compose.yml logs station-a station-b`.

## Note on the video

The video itself is a separate ask. This run sheet is designed for a silent 90-second cut with
captions; no audio is needed. The dashboard is legible at 1080p: four freezer cards per row, the
two site cards, the provider table, and the gateway audit table are the only moving parts.
