# Spade

DNS security inspector. Checks six records that quietly do security work for your domain — in parallel, with live results.

**Checks:** SPF · DMARC · CAA · DNSSEC · MTA-STS · DKIM

Each card shows the raw record value, a pass/warn/fail verdict, and the exact record to publish if something is missing or misconfigured.

## Run

```bash
docker compose up -d
# or
podman compose up -d
```

Serves on port **8484** by default. Change in `compose.yml`.

## How it works

Pure static HTML — no backend, no build step. DNS queries go directly from the browser to [Google's DNS-over-HTTPS API](https://developers.google.com/speed/public-dns/docs/doh/json). Nothing is sent to or stored on the server.

## Stack

- [`joseluisq/static-web-server`](https://static-web-server.net/) — scratch-based static file server (~6 MB image)
- `sws.toml` — security headers (CSP, X-Frame-Options, etc.)
- `compose.yml` — port mapping, healthcheck, restart policy

## What each check covers

| Check | What it catches |
|-------|----------------|
| SPF | Missing or soft-fail (`~all`) records that let anyone spoof your domain |
| DMARC | `p=none` policies that monitor but enforce nothing |
| CAA | Missing CA restrictions — any CA can issue certs for your domain |
| DNSSEC | Zone signed but DS not published at registrar (chain broken) |
| MTA-STS | SMTP downgrade attacks; verifies policy file mode |
| DKIM | Probes 20 common selectors to confirm signing is active |

The part people miss: having a record and enforcing it are two different states. `p=none`, `~all`, and `mode=testing` all look configured and protect nothing.
