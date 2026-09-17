#!/usr/bin/env bash
# End-to-end check of the webhook receiver against a running server + DB.
# Hand-firing a signed webhook with openssl is the same trick you use to test a
# vendor integration when you can't make the vendor send you a real event.
set -euo pipefail

URL=${URL:-http://localhost:8000/webhook/github}
SECRET=${WEBHOOK_SECRET:-dev-secret}
BODY='{"zen":"Keep it logically awesome.","hook_id":42}'
DELIVERY=$(uuidgen)

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print "sha256="$NF}'; }

# Returns the HTTP status and body for one POST. $2 is the signature header value.
fire() {
  curl -sS -o /tmp/smoke.out -w '%{http_code}' -X POST "$URL" \
    -H "X-GitHub-Event: ping" \
    -H "X-GitHub-Delivery: $1" \
    -H "X-Hub-Signature-256: $2" \
    -H 'Content-Type: application/json' \
    --data-raw "$BODY"
}

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $3"; exit 1; fi
}

echo "delivery id: $DELIVERY"

# 1. Forged signature must be rejected before we touch the DB.
code=$(fire "$DELIVERY" "sha256=$(printf '0%.0s' {1..64})")
check "bad signature rejected" 401 "$code"

# 2. First genuine delivery is stored.
sig=$(sign "$BODY")
code=$(fire "$DELIVERY" "$sig")
check "good signature accepted" 200 "$code"
check "first delivery stored" '{"stored":true,"duplicate":false}' "$(cat /tmp/smoke.out)"

# 3. GitHub's retry of the same delivery is a no-op, not a second row.
code=$(fire "$DELIVERY" "$sig")
check "retry accepted" 200 "$code"
check "retry deduped" '{"stored":false,"duplicate":true}' "$(cat /tmp/smoke.out)"

# 4. The DB must agree: exactly one row for this delivery id.
rows=$(docker compose exec -T db psql -U lab -d lab -tAc \
  "SELECT count(*) FROM webhook_deliveries WHERE delivery_id = '$DELIVERY'")
check "exactly one row in DB" 1 "$rows"

echo "all good"
