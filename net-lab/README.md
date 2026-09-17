# Network diagnosis drill

Five broken-connectivity scenarios, each failing at a different layer. Nothing is
published to the host: you diagnose from inside a container, which is the position
you are in on a customer's box.

```bash
docker compose up -d
docker compose exec diag sh          # your toolbox: ip, ss, dig, curl, tcpdump
```

| Target (from `diag`) | What's wrong |
|---|---|
| `http://good/` | nothing -- this is the baseline |
| `http://bound-local/` | service is up, bound to loopback only |
| `http://wrongport/` | service is up on all interfaces, different port |
| `http://blackhole/` | name resolves to an unroutable address |
| `http://ghost/` | name does not exist |
| `http://good/` **from `diag-baddns`** | DNS server is unreachable |

## The fixed order

Work downward. Each step assumes the ones above it passed -- that is the whole value,
it stops you tcpdumping a DNS problem.

1. **Name → address.** `dig +short <name>` / `getent hosts <name>`. No answer, or a
   hang, and you are done: it is DNS, not the service.
2. **Address → route.** `ip route get <ip>` -- is there a path, and out which
   interface? `ip addr` for what this box even is.
3. **Route → TCP.** `curl -v` or `nc -vz <host> <port>`. Three outcomes, three
   different meanings:
   - **connected** -- move to step 5
   - **refused** -- you reached the host; nothing is listening on that port *at that
     address*. A live host said no.
   - **timeout / hang** -- nothing answered at all. Packets are being dropped,
     blackholed, or sent somewhere that does not exist.
4. **Who is listening, really?** On the server: `ss -ltnp`. Read the *address* column,
   not just the port -- `127.0.0.1:80` and `0.0.0.0:80` are completely different
   situations, and this is the single most common cause of "but the service is running".
5. **Application.** Now, and only now, is it HTTP's problem: status codes, TLS, auth.

## The distinction to internalise

**Refused is an answer. Timeout is silence.**

Refused means the packet arrived, a host processed it and actively rejected it (TCP
RST): wrong port, service down, bound elsewhere. Something is alive there.

Timeout means nobody replied: wrong address, no route, a firewall dropping silently, or
a host that does not exist. Nothing proved alive.

Those two symptoms send you to opposite halves of the stack. Getting them the wrong way
round is how people spend an afternoon restarting a service that was never the problem.
