-- Runs once, on first init of an empty pgdata volume.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE github_events (
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

SELECT create_hypertable('github_events', 'created_at');
CREATE INDEX ON github_events (type, created_at DESC);
