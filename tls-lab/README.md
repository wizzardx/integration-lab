# TLS lab

Four TLS faults, one per port, all served by the same nginx from the same PKI.
Each port changes exactly one variable, so the error you get is attributable.

```bash
./make-certs.sh          # build the PKI (root -> intermediate -> leaf + 3 broken variants)
docker compose up -d
```

The leaf's only SAN is `lab.local`, and nothing resolves that name, so every test
uses `--resolve` (curl) or `-servername` (openssl). That is deliberate: it forces
you to state the name you are claiming to be, which is what SNI and hostname
verification actually check.

| Port | What's on it |
|---|---|
| 8443 | Correct: leaf + intermediate, in date, SAN `lab.local` |
| 8444 | Expired leaf (valid Jan 2020), otherwise the same trusted chain |
| 8445 | Right hostname, in date, signed by a CA you don't trust |
| 8446 | The *same good leaf* as 8443, served without its intermediate |

## The two commands

```bash
# curl: the client's verdict. Exit code + one-line reason.
curl -v --cacert certs/rootCA.crt --resolve lab.local:8443:127.0.0.1 https://lab.local:8443/

# openssl: what is actually on the wire, regardless of whether it verifies.
openssl s_client -connect 127.0.0.1:8443 -servername lab.local \
  -CAfile certs/rootCA.crt -showcerts </dev/null
```

`curl` tells you *that* it failed. `s_client` tells you *why*: read `Verify return code`,
then the `Certificate chain` block — depth 0 is the leaf, and each depth above it is a
cert the server chose to send.

## Fixed diagnosis order

Run this in the same order every time; it moves from cheapest to most specific.

1. **Did TLS even start?** `Connection refused` / `reset` is a network or listener
   problem, not a certificate problem. Stop and fix that first.
2. **What did the server send?** `s_client -showcerts` — count the certs. How many
   depths? Does the top one chain to something you trust?
3. **Who signed the leaf?** `openssl x509 -noout -issuer -subject` on depth 0. Does
   the issuer match a cert the server sent, or one you hold?
4. **Is it in date?** `openssl x509 -noout -dates`. Compare against `date -u`.
5. **Does the name match?** `s_client` prints the SAN; is the name you connected as
   in it? Note that `-servername` (what you claim) and the SAN (what the cert allows)
   are two different things.
6. **Only then blame trust:** `openssl verify -CAfile ... -untrusted ... leaf.crt`
   reproduces the verdict offline, with no server involved.

## The one that matters

8445 and 8446 produce a **near-identical** curl error, from opposite causes: one is a
cert you should never trust, the other is a cert you should trust but can't reach the
root of. Telling them apart from the client's error message alone is impossible — you
have to look at the chain the server sent. That distinction is most of real-world TLS
debugging, and it's why "just add the CA" is so often the wrong fix.
