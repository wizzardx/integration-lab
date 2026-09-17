-- Runs automatically on first init of an empty pgdata volume, and is
-- re-runnable by hand (psql -f schema.sql) when we add tables mid-project.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS github_events (
    created_at   timestamptz NOT NULL,
    id           text        NOT NULL,
    type         text        NOT NULL,
    actor        text        NOT NULL,
    public       boolean     NOT NULL,
    ingested_at  timestamptz NOT NULL DEFAULT now(),
    -- Timescale requires the partitioning column in every unique index, so
    -- idempotency is keyed on (created_at, id) rather than id alone. Safe here:
    -- GitHub never changes an event's timestamp.
    PRIMARY KEY (created_at, id)
);

SELECT create_hypertable('github_events', 'created_at', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS github_events_type_time ON github_events (type, created_at DESC);

-- Deliberately NOT a hypertable: the only timestamp we have is receipt time,
-- which differs between GitHub's original delivery and its retries. Keying on
-- (received_at, delivery_id) would let a retry in as a new row, so the PK is
-- delivery_id alone -- which a hypertable would forbid.
CREATE TABLE IF NOT EXISTS webhook_deliveries (
    delivery_id  uuid        PRIMARY KEY,
    event        text        NOT NULL,
    received_at  timestamptz NOT NULL DEFAULT now(),
    payload      jsonb       NOT NULL
);
