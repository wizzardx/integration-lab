"""Inbound half of the integration: a GitHub webhook receiver.

Same DB as poller.py, opposite direction -- GitHub pushes to us. Two things
matter at this trust boundary: prove the request is really from GitHub (HMAC
over the raw body), and make retries harmless (idempotency on delivery id).
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import sys
from typing import Annotated

import psycopg
from fastapi import FastAPI, Header, HTTPException, Request

DSN = os.environ.get("DATABASE_URL", "postgresql://lab:lab@localhost:5432/lab")
SECRET = os.environ.get("WEBHOOK_SECRET", "dev-secret")

log = logging.getLogger("webhook")
app = FastAPI()

INSERT = """
    INSERT INTO webhook_deliveries (delivery_id, event, payload)
    VALUES (%s, %s, %s)
    ON CONFLICT (delivery_id) DO NOTHING
"""


def verify(body: bytes, header: str | None) -> bool:
    """Constant-time compare of GitHub's X-Hub-Signature-256 over the raw body.

    Must be the raw bytes, not re-serialised JSON: any whitespace or key-order
    difference changes the digest.
    """
    if not header:
        return False
    expected = "sha256=" + hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


@app.post("/webhook/github")
async def receive(
    request: Request,
    x_github_event: Annotated[str, Header()],
    x_github_delivery: Annotated[str, Header()],
    x_hub_signature_256: Annotated[str | None, Header()] = None,
) -> dict:
    body = await request.body()
    if not verify(body, x_hub_signature_256):
        # Log the delivery id, never the body: unverified input is attacker-controlled.
        log.warning("signature rejected", extra={"ctx": {"delivery": x_github_delivery}})
        raise HTTPException(401, "bad signature")

    # ponytail: one connection per delivery; use psycopg_pool if volume ever matters
    with psycopg.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute(INSERT, (x_github_delivery, x_github_event, body.decode()))
        stored = cur.rowcount == 1

    log.info("delivery", extra={"ctx": {"event": x_github_event, "delivery": x_github_delivery, "stored": stored}})
    # 200 either way: a duplicate is success from GitHub's point of view, and a
    # non-2xx would make it retry a delivery we already have.
    return {"stored": stored, "duplicate": not stored}


def demo() -> None:
    """Offline check of the signature logic -- the part with security consequences."""
    body = b'{"zen":"Keep it logically awesome."}'
    good = "sha256=" + hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
    assert verify(body, good)
    assert not verify(body, None)
    assert not verify(body, "sha256=" + "0" * 64)      # wrong digest
    assert not verify(body, good.removeprefix("sha256="))  # missing prefix
    assert not verify(body + b" ", good)               # body tampered by one byte
    print("ok")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    demo() if "--demo" in sys.argv else sys.exit("run with: uv run uvicorn webhook:app --reload")
