"""Poll GitHub repo events -> JSON lines on stdout.

Tier 1 step 1: token auth, Link-header pagination, retries with backoff,
rate-limit handling, structured logs, pydantic validation. Postgres next step.
"""

from __future__ import annotations

import json
import logging
import os
import random
import sys
import time
from datetime import datetime

import httpx
import psycopg
from pydantic import BaseModel, field_validator

REPO = os.environ.get("GH_REPO", "pydantic/pydantic")
DSN = os.environ.get("DATABASE_URL", "postgresql://lab:lab@localhost:5432/lab")
TOKEN = os.environ.get("GITHUB_TOKEN")  # optional: 60 req/h without, 5000 with
MAX_TRIES = 5
LOW_QUOTA = 5  # requests left before we wait for the window to reset

log = logging.getLogger("poller")


class JsonFormatter(logging.Formatter):
    """One JSON object per log line: greppable by hand, parseable by Graylog."""

    def format(self, record: logging.LogRecord) -> str:
        out = {"ts": self.formatTime(record), "level": record.levelname, "msg": record.getMessage()}
        out.update(getattr(record, "ctx", {}))
        return json.dumps(out)


class Event(BaseModel):
    """The subset of a GitHub event we care about, flattened for one DB row."""

    id: str
    type: str
    created_at: datetime
    actor: str
    public: bool

    @field_validator("actor", mode="before")
    @classmethod
    def _login(cls, v):
        return v["login"] if isinstance(v, dict) else v


def retry_after(status: int, headers, attempt: int) -> float | None:
    """Seconds to wait before retrying, or None if the error is not retryable."""
    if status in (429, 500, 502, 503, 504) or (
        status == 403 and headers.get("x-ratelimit-remaining") == "0"
    ):
        if (ra := headers.get("retry-after")) and ra.isdigit():
            return float(ra)
        if reset := headers.get("x-ratelimit-reset"):
            return max(0.0, float(reset) - time.time()) + 1
        # Exponential backoff with full jitter: without the random factor, every
        # client that hit the same outage retries in lockstep and re-DDoSes the API.
        return random.uniform(0, 2.0**attempt)
    return None


def throttle(headers) -> None:
    """Pre-emptively sleep out the rate-limit window instead of earning a 403."""
    remaining = headers.get("x-ratelimit-remaining")
    if remaining is not None and int(remaining) <= LOW_QUOTA:
        wait = max(0.0, float(headers["x-ratelimit-reset"]) - time.time()) + 1
        log.warning("rate limit low, sleeping", extra={"ctx": {"remaining": remaining, "sleep": round(wait, 1)}})
        time.sleep(wait)


def get(client: httpx.Client, url: str, **params) -> httpx.Response:
    for attempt in range(MAX_TRIES):
        r = client.get(url, params=params or None)
        if r.is_success:
            throttle(r.headers)
            return r
        wait = retry_after(r.status_code, r.headers, attempt)
        if wait is None:
            r.raise_for_status()
        log.warning("retrying", extra={"ctx": {"url": url, "status": r.status_code, "sleep": round(wait, 1), "attempt": attempt}})
        time.sleep(wait)
    raise RuntimeError(f"gave up on {url} after {MAX_TRIES} tries")


def events(repo: str):
    """Yield pages of validated events, following Link: rel=next until GitHub stops."""
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    with httpx.Client(headers=headers, timeout=10) as client:
        url, params = f"https://api.github.com/repos/{repo}/events", {"per_page": 100}
        while url:
            r = get(client, url, **params)
            yield [Event.model_validate(raw) for raw in r.json()]
            # ponytail: events endpoint caps at ~300 items; cursor/ETag polling in step 1b
            url, params = r.links.get("next", {}).get("url"), {}


UPSERT = """
    INSERT INTO github_events (created_at, id, type, actor, public)
    VALUES (%s, %s, %s, %s, %s)
    ON CONFLICT (created_at, id) DO NOTHING
"""


def store(conn, batch: list[Event]) -> int:
    """Insert a page, skipping events we already have. Returns rows actually new."""
    with conn.cursor() as cur:
        cur.executemany(UPSERT, [(e.created_at, e.id, e.type, e.actor, e.public) for e in batch])
        return cur.rowcount


def demo() -> None:
    """Offline self-check of the two bits of logic that are easy to get wrong."""
    assert retry_after(404, {}, 0) is None
    assert 0 <= retry_after(500, {}, 3) <= 8.0   # jittered, so a range not a value
    assert retry_after(429, {"retry-after": "7"}, 0) == 7.0
    assert retry_after(403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(time.time() + 30)}, 0) > 29
    e = Event.model_validate({"id": "1", "type": "PushEvent", "created_at": "2026-09-16T10:00:00Z",
                              "actor": {"login": "dave"}, "public": True, "payload": {"ignored": 1}})
    assert e.actor == "dave"
    print("ok")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, handlers=[logging.StreamHandler(sys.stderr)])
    logging.getLogger().handlers[0].setFormatter(JsonFormatter())
    logging.getLogger("httpx").setLevel(logging.WARNING)  # one INFO line per request is noise
    if "--demo" in sys.argv:
        demo()
    else:
        seen = new = 0
        with psycopg.connect(DSN) as conn:  # commits on clean exit, rolls back on exception
            for page in events(REPO):
                seen += len(page)
                new += store(conn, page)
                log.info("page stored", extra={"ctx": {"fetched": len(page), "new": new}})
        log.info("done", extra={"ctx": {"repo": REPO, "seen": seen, "new": new, "token": bool(TOKEN)}})
