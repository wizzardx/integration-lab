# Sintrex onboarding prep — coding partner brief

## Who I am
Senior backend engineer, 23+ years, self-taught. Strong: Python, Linux/Debian
(20+ yrs admin), PostgreSQL, RabbitMQ, Docker, shell. Weak/rusty: writing FastAPI
by hand (previous work was vibe-coded), HTML/JS/CSS, Node.js/TypeScript,
Elasticsearch, TLS debugging, GitHub Actions. No AWS needed for this.

## Context
Starting 1 Oct (or 1 Nov) as Senior DevOps Engineer (Integration Specialist) at
Sintrex Integration Services, Cape Town — an IT monitoring/integration company.
The job: investigate, build, deploy and support integrations that extract
operational data from vendor/customer platforms (e.g. Microsoft Teams Rooms via
Graph, Juniper Mist, Jablotron, ThousandEyes) via APIs/webhooks/SNMP/syslog/
exports, land it in a store (PostgreSQL, TimescaleDB, Elasticsearch, Graylog,
MariaDB, MongoDB, SQLite), validate in Grafana, and produce field mappings,
docs and user stories. Stack also includes Node.js/TypeScript/Vue, Bash,
Windows Server, networking. Fully office-based, 08:00–17:00, likely some
after-hours support.

## How I want to work
- Vibe-coded: you write the code, I run it, we iterate. Keep me in the loop
  on WHAT each piece does and WHY, in 2–3 sentences per step — I need to be
  able to explain this work in my first week, not reproduce it from memory.
- Debian Linux, Docker Compose, Python 3.12, uv or venv, GitHub.
- Terse, structured replies. Code in files, not pasted inline, once it's
  >20 lines. Comment the non-obvious parts.
- One step at a time. Tell me what to run, wait for output, then continue.
- When something breaks, walk me through the diagnosis rather than just
  fixing it — the diagnostic habit is half the point.
- Time budget: ~2 weeks, evenings + some full days. Tier 1 is non-negotiable;
  later tiers are breadth, not depth.

## The plan (work through in order, tell me where we are)

### Tier 1 — end-to-end integration pipeline (~5 days)
Goal: one working artefact I can describe as "an integration I built last
week". Repo name: `integration-lab`.
1. Python poller against a real, messy public REST API (GitHub or Open-Meteo
   are fine): token auth, pagination, retries with backoff, rate-limit
   handling, structured logging, pydantic models. Writes to PostgreSQL.
2. FastAPI webhook receiver doing the inbound equivalent (HMAC verification,
   idempotency on event id, same DB).
3. Docker Compose: PostgreSQL + TimescaleDB extension + Grafana. Hypertable
   for the time-series data. Grafana dashboard with 2–3 panels and one alert
   rule.
4. Docs: a field-mapping table (source field → our column → type → notes),
   a short README, and one user story in "As a / I want / So that" form.

### Tier 2 — assessment gaps (~3 days)
1. TLS lab: self-signed CA + server cert in Docker; deliberately break it
   (expired, wrong SNI, missing intermediate, untrusted CA) and diagnose each
   with `openssl s_client` and `curl -v`.
2. Network diagnosis drill: give me broken-connectivity scenarios in
   containers; I diagnose with ip/ss/dig/curl/tcpdump in a fixed order,
   you grade the approach.
3. GitHub Actions: build the Tier 1 image, tag by SHA, push to GHCR.
   Explain the immutable-image idea as we go.

### Tier 3 — their stack I don't have (~3 days, breadth only)
1. Node.js/TypeScript: a small Express-style service equivalent to the
   FastAPI webhook receiver, so I can read and patch existing Node code.
2. Elasticsearch + Graylog in Compose: index the same events, run a few
   queries, look at a mapping. Stop there.
3. SNMP: snmpd in a container, snmpwalk it, poll one OID from Python into
   Timescale. Syslog: ship container logs to Graylog. NetFlow: concept only.
4. MariaDB and MongoDB: 30 min each on how they differ from Postgres for
   the same schema.

### Tier 4 — reading (evenings, no code)
Microsoft Graph (Teams Rooms) and Juniper Mist API auth models and endpoint
overviews; ThousandEyes API overview; basic PowerShell/WinRM.

## Start
Confirm you've understood the brief in 3 lines, then begin Tier 1 step 1:
propose the repo layout and the first file.
