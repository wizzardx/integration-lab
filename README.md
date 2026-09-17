# integration-lab

An end-to-end integration: pull operational data out of a third-party platform
(GitHub), land it in TimescaleDB, and validate it in Grafana. Two directions,
because real vendor integrations come in both:

| Direction | Component | Trigger |
|---|---|---|
| Outbound poll | `poller.py` | we call GitHub's REST API on a schedule |
| Inbound push | `webhook.py` | GitHub POSTs to us when an event happens |

Both write to the same Postgres/Timescale instance; Grafana reads it.

## Run it

```bash
docker compose up -d                 # Timescale + Grafana, schema applied on first boot
uv run python poller.py              # backfill events (set GITHUB_TOKEN for 5000 req/h)
uv run uvicorn webhook:app --reload  # inbound receiver on :8000
./smoke.sh                           # signed/forged/replayed webhook, asserts DB state
uv run python poller.py --demo       # offline self-checks (retry + parsing logic)
uv run python webhook.py --demo      # offline self-checks (HMAC verification)
```

Grafana: http://localhost:3000 → *Integration Lab*. Datasource, dashboard and
alert rule are all provisioned from `grafana/provisioning/`, so a wiped volume
comes back identical — nothing is configured by clicking.

## Field mapping

Source: `GET /repos/{owner}/{repo}/events` ([events API](https://docs.github.com/en/rest/activity/events)) → table `github_events`.
Only these fields are kept; the rest of the payload is dropped deliberately.

| Source field | Our column | Type | Notes |
|---|---|---|---|
| `created_at` | `created_at` | `timestamptz` | Event time at GitHub. Hypertable partition key. UTC (`Z`) in the API. |
| `id` | `id` | `text` | Numeric-looking but a string in the API — kept as text, never arithmetic on it. |
| `repo.name` | `repo` | `text` | `"owner/name"`. Flattened from a nested object. Taken from the event itself, not the repo we asked for, so a rename/redirect is recorded accurately. |
| `type` | `type` | `text` | e.g. `PushEvent`. Not an enum: GitHub adds types without notice. |
| `actor.login` | `actor` | `text` | Flattened from a nested object by a pydantic validator. |
| `public` | `public` | `boolean` | Always true on this endpoint; kept so the column exists if we move to an authed feed. |
| — | `ingested_at` | `timestamptz` | Ours, `default now()`. The gap between this and `created_at` is ingest lag. |
| `payload`, `org` | — | — | Dropped: `payload`'s shape varies per `type`, nothing downstream needs it yet. |

Source: GitHub webhook POST → table `webhook_deliveries`.

| Source field | Our column | Type | Notes |
|---|---|---|---|
| `X-GitHub-Delivery` header | `delivery_id` | `uuid` PK | Idempotency key. GitHub reuses it on retry, so the PK makes a replay a no-op. |
| `X-GitHub-Event` header | `event` | `text` | Event name; the body shape depends on it. |
| raw request body | `payload` | `jsonb` | Stored whole and unparsed — we can't know yet which fields matter. |
| — | `received_at` | `timestamptz` | Ours, `default now()`. Receipt time, not event time. |
| `X-Hub-Signature-256` header | — | — | Verified against the raw bytes, then discarded. |

### Decisions worth knowing

- `github_events` is a **hypertable** on `created_at`; Timescale requires the
  partition key in every unique index, so idempotency is `PRIMARY KEY (created_at, id)`.
  Safe because GitHub never changes an event's timestamp.
- `webhook_deliveries` is deliberately **not** a hypertable: its only timestamp is
  receipt time, which differs between a delivery and its retry, so a composite key
  would let a duplicate in. PK is `delivery_id` alone.
- The webhook returns **200 on a duplicate**. A non-2xx would make GitHub retry a
  delivery we already have.
- HMAC is computed over the **raw body**, never re-serialised JSON — any whitespace
  or key-order change alters the digest.

## Monitoring

Dashboard panels: events/hour by type, ingest lag, top actors, recent webhook
deliveries, events per repo. One alert rule, `GitHub ingest stalled`: fires when fewer than 1 row
landed in the last hour, `for: 5m`, `noDataState: Alerting`. Silence from a poller
is indistinguishable from a quiet period unless something watches for it.

## User story

> **As a** network operations engineer,
> **I want** activity from our vendor platforms recorded in one time-series store with a dashboard and a staleness alert,
> **so that** I can see what changed and when during an incident, and find out that the feed itself has died without a customer telling me.

## Known limits

- The events endpoint caps at ~300 items / 90 days; a real deployment needs
  ETag-based polling on a schedule, not a backfill loop.
- One DB connection per webhook delivery — fine at lab volume, needs a pool
  beyond that.
- Grafana anonymous admin and plaintext DB passwords: lab only.
