# Freezer controller (mock)

The deliberately vulnerable "as-is" OT controller in the lab. It simulates four freezers, exposes
an unauthenticated read API and a basic-auth write API, and records writes in a simple audit log.

```bash
mix deps.get
mix test
PORT=8080 mix run --no-halt
```

The controller is normally run by the Compose stack in `deploy/compose.yml`; see the repository
root README for the full demo. The default `admin/admin` account and the open read endpoints are
intentional: they model the exposed remote-management module, not a production design.
