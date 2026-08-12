```
  ____  ____   _   ____  _____
 / ___||  _ \ / \ |  _ \| ____|
 \___ \| |_) / _ \| | | |  _|
  ___) |  __/ ___ \ |_| | |___
 |____/|_| /_/   \_\____/|_____|

  ♠  DNS Security Inspector
```

[![CI](https://github.com/slmingol/spade--dns-inspector/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/slmingol/spade--dns-inspector/actions/workflows/docker-publish.yml)
[![GitHub release](https://img.shields.io/github/v/release/slmingol/spade--dns-inspector?include_prereleases)](https://github.com/slmingol/spade--dns-inspector/releases)
[![GitHub last commit](https://img.shields.io/github/last-commit/slmingol/spade--dns-inspector)](https://github.com/slmingol/spade--dns-inspector/commits/main)
[![GitHub commit activity](https://img.shields.io/github/commit-activity/m/slmingol/spade--dns-inspector)](https://github.com/slmingol/spade--dns-inspector/commits/main)
[![GitHub issues](https://img.shields.io/github/issues/slmingol/spade--dns-inspector)](https://github.com/slmingol/spade--dns-inspector/issues)
[![GitHub repo size](https://img.shields.io/github/repo-size/slmingol/spade--dns-inspector)](https://github.com/slmingol/spade--dns-inspector)
[![Docker Image](https://ghcr-badge.egpl.dev/slmingol/spade-dns-inspector/size?label=image%20size)](https://github.com/slmingol/spade--dns-inspector/pkgs/container/spade-dns-inspector)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Go](https://img.shields.io/badge/Go-1.23-00ADD8?logo=go&logoColor=white)](https://go.dev)
[![Container](https://img.shields.io/badge/container-scratch--based-lightgrey?logo=docker)](https://github.com/slmingol/spade--dns-inspector/pkgs/container/spade-dns-inspector)

DNS security inspector. Checks six records that quietly do security work for your domain — in parallel, with live results and a letter grade.

**Checks:** SPF · DMARC · CAA · DNSSEC · MTA-STS · DKIM

Each card shows the raw record value, a pass/warn/fail verdict, and the exact record to publish if something is missing or misconfigured. A graded summary (A–F, scored out of 100) appears after all checks complete. A reference table at the bottom explains pass/warn/fail conditions and example records for each check.

## Run

```bash
docker compose up -d
```

Serves on port **8484** by default. Change in `docker-compose.yaml`.

## How it works

Single Go binary — serves static files from `/public` and exposes a `/resolve` endpoint that does DNS lookups server-side using the system resolver (standard port 53). The browser calls `/resolve` instead of external DNS-over-HTTPS APIs, so it works behind firewalls that block outbound DoH (port 443 to dns.google / cloudflare-dns.com).

MTA-STS policy files are also fetched server-side via `/fetch`, eliminating CORS issues.

Nothing is stored. All DNS queries happen at request time and are not logged.

## Stack

- Go binary — static file server + DNS proxy + MTA-STS policy fetcher
- Multi-stage Docker build: `golang:1.23-alpine` builder → `scratch` final image (~15 MB)
- CI via GitHub Actions → pushes to `ghcr.io/slmingol/spade-dns-inspector:latest`

## What each check covers

| Check | What it catches |
|-------|----------------|
| SPF | Missing or soft-fail (`~all`) records that let anyone spoof your domain |
| DMARC | `p=none`/`p=quarantine` policies that don't fully enforce rejection |
| CAA | Missing CA restrictions — any CA can issue certs for your domain |
| DNSSEC | Zone unsigned — DNS responses can be spoofed or poisoned |
| MTA-STS | SMTP downgrade attacks; fetches and reads policy file mode |
| DKIM | Probes 20 common selectors to confirm cryptographic signing is active |

The part people miss: having a record and enforcing it are two different states. `p=none`, `~all`, and `mode: testing` all look configured and protect nothing.

## Grading

Scored out of 100 based on check outcomes:

| Check | Pass | Warn | Fail |
|-------|------|------|------|
| DMARC | 35 | 20 | 0 |
| SPF | 25 | 12 | 0 |
| DKIM | 20 | 10 | 0 |
| MTA-STS | 8 | 4 | 0 |
| CAA | 7 | 3 | 0 |
| DNSSEC | 5 | 3 | 3 |

| Grade | Score | Meaning |
|-------|-------|---------|
| A | 85–100 | Strong DNS security posture |
| B | 65–84 | Core email security solid, some hardening gaps |
| C | 45–64 | Basic protection in place, notable gaps remain |
| D | 25–44 | Significant gaps, spoofing risk elevated |
| F | 0–24 | Missing core protections, immediate action needed |

DNSSEC fail only deducts 2 points — it is rarely deployed even by serious operators, and the infrastructure requirement (both DNS provider and registrar must support it) puts it in a different category from the email checks.

## Fixing common issues

### DMARC — escalate to reject

Edit the TXT record at `_dmarc.yourdomain`:
```
v=DMARC1; p=reject; rua=mailto:postmaster@yourdomain
```
Start at `p=quarantine` if you want a burn-in period, then escalate.

### SPF — use hard fail

Ensure the record ends with `-all` not `~all`:
```
v=spf1 include:your-mail-provider.com -all
```

### CAA — restrict certificate issuance

Add three CAA records (check your current cert issuer first — padlock in browser → Certificate → Issuer):
```
0 issue "letsencrypt.org"
0 issuewild ";"
0 iodef "mailto:postmaster@yourdomain"
```

### DNSSEC — enable at DNS provider

Cloudflare: DNS tab → DNSSEC section → Enable. Cloudflare generates the DS record values. Add them at your domain registrar. If your domain is registered with Cloudflare it is automatic.

### MTA-STS — two parts

**1. TXT record** at `_mta-sts.yourdomain`:
```
v=STSv1; id=20260101000000
```
Update the `id=` timestamp whenever you change the policy.

**2. Policy file** served over HTTPS at `https://mta-sts.yourdomain/.well-known/mta-sts.txt`:
```
version: STSv1
mode: enforce
mx: mx1.your-mail-provider.com
mx: mx2.your-mail-provider.com
max_age: 86400
```
MX hostnames must match your actual MX records exactly. Start with `mode: testing`, verify no delivery issues, then switch to `mode: enforce`.

Options for hosting the policy file: Cloudflare Worker, Cloudflare Pages, or any web server already mapped to the `mta-sts` subdomain.

#### Cloudflare Worker option (free, no server required)

Cloudflare Workers can host the policy file on the free tier (100k requests/day). The key detail: you must create a **script worker**, not a static assets worker. The dashboard offers both and it is easy to create the wrong type.

**Step 1 — create the worker**

Workers & Pages → Create → **Start with Hello World** (not "Upload static assets", not "Build from template"). This creates a script worker with a JavaScript fetch handler.

**Step 2 — replace the default code**

In the editor that opens, delete everything and paste:

```javascript
export default {
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== '/.well-known/mta-sts.txt') {
      return new Response('Not found', { status: 404 });
    }
    return new Response(
      `version: STSv1
mode: enforce
mx: mx1.your-mail-provider.com
mx: mx2.your-mail-provider.com
max_age: 86400`,
      { headers: { 'Content-Type': 'text/plain' } }
    );
  }
};
```

Replace the `mx:` lines with your actual MX hostnames (must match `dig MX yourdomain` output exactly).

Test in the preview pane: change the URL to `https://your-worker.workers.dev/.well-known/mta-sts.txt` — all 5 lines of the policy should appear. Click **Deploy**.

**Step 3 — add the custom domain**

Domains tab → Add Domain → `mta-sts.yourdomain`. Cloudflare automatically creates a CNAME in your DNS zone pointing to the worker. No manual DNS record needed.

**Step 4 — add the TXT record**

In Cloudflare DNS, add a TXT record:

| Name | Type | Content |
|------|------|---------|
| `_mta-sts` | TXT | `v=STSv1; id=20260101000000` |

Update `id=` to the current date in `YYYYMMDDHHMMSS` format whenever you change the policy file. Receiving MTAs use this value to detect policy changes.

**Verify end to end:**

```bash
curl https://mta-sts.yourdomain/.well-known/mta-sts.txt
dig TXT _mta-sts.yourdomain
```

Both must return data before Spade will show MTA-STS as pass.

**Common failure: wrong worker type**

If the worker overview shows "Metrics is unavailable for Workers with only static assets" — wrong type was created. A static assets worker has no fetch handler so every request returns 404. Delete it (Settings → Delete Worker) and recreate from Hello World.

**Common failure: `max_age` missing**

If curl returns the policy but `max_age` is absent, the worker was built with a single-quoted string containing `\n` escape sequences that Cloudflare's editor rendered as literal backslash-n. Use a template literal (backtick string with real newlines) as shown above.
