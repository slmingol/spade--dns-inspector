#!/usr/bin/env bash
# Deploy MTA-STS policy as a Cloudflare Worker with custom domain + TXT record.
#
# Required env vars:
#   DOMAIN          - bare domain, e.g. example.com
#   MX_RECORDS      - space-separated MX hostnames, e.g. "mx1.provider.com mx2.provider.com"
#   CF_API_TOKEN    - Cloudflare API token (Workers Scripts:Edit + DNS:Edit on zone)
#   CF_ZONE_ID      - Cloudflare Zone ID (dashboard → domain → right sidebar)
#
# Optional:
#   MTA_STS_MODE    - testing|enforce (default: enforce)
#   MTA_STS_MAX_AGE - seconds (default: 86400)
#   WORKER_NAME     - override generated name (default: mta-sts-<domain-dashes>)
#
# Usage:
#   DOMAIN=example.com \
#   MX_RECORDS="mx1.simplelogin.co mx2.simplelogin.co" \
#   CF_API_TOKEN=xxx \
#   CF_ZONE_ID=yyy \
#   ./deploy.sh

set -euo pipefail

# Load .env if present (in same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

: "${DOMAIN:?set DOMAIN}"
: "${MX_RECORDS:?set MX_RECORDS (space-separated hostnames)}"
: "${CF_API_TOKEN:?set CF_API_TOKEN}"
: "${CF_ZONE_ID:?set CF_ZONE_ID}"

MODE="${MTA_STS_MODE:-enforce}"
MAX_AGE="${MTA_STS_MAX_AGE:-86400}"
WORKER_NAME="${WORKER_NAME:-mta-sts-${DOMAIN//./-}}"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Build MX lines for policy file
MX_LINES=""
for mx in $MX_RECORDS; do
  MX_LINES+="mx: ${mx}"$'\n'
done
# Trim trailing newline
MX_LINES="${MX_LINES%$'\n'}"

echo "==> Domain:      $DOMAIN"
echo "==> Worker name: $WORKER_NAME"
echo "==> Mode:        $MODE"
echo "==> MX records:  $MX_RECORDS"
echo "==> Tmpdir:      $TMPDIR"
echo ""

# --- Generate worker.js ---
cat > "$TMPDIR/worker.js" <<WORKER
export default {
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== '/.well-known/mta-sts.txt') {
      return new Response('Not found', { status: 404 });
    }
    return new Response(
      \`version: STSv1
mode: ${MODE}
${MX_LINES}
max_age: ${MAX_AGE}\`,
      { headers: { 'Content-Type': 'text/plain' } }
    );
  }
};
WORKER

# --- Generate wrangler.toml ---
cat > "$TMPDIR/wrangler.toml" <<TOML
name = "${WORKER_NAME}"
main = "worker.js"
compatibility_date = "2024-09-23"

[[routes]]
pattern = "mta-sts.${DOMAIN}"
custom_domain = true
TOML

echo "==> worker.js:"
cat "$TMPDIR/worker.js"
echo ""
echo "==> wrangler.toml:"
cat "$TMPDIR/wrangler.toml"
echo ""

# --- Deploy worker ---
echo "==> Deploying worker..."
cd "$TMPDIR"
CLOUDFLARE_API_TOKEN="$CF_API_TOKEN" wrangler deploy --config wrangler.toml
echo ""

# --- Upsert _mta-sts TXT record ---
echo "==> Upserting _mta-sts TXT record..."

TXT_NAME="_mta-sts.${DOMAIN}"
TXT_CONTENT="v=STSv1; id=${TIMESTAMP}"

# Check if record exists
EXISTING=$(curl -s -X GET \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=TXT&name=${TXT_NAME}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json")

RECORD_ID=$(echo "$EXISTING" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -n "$RECORD_ID" ]; then
  echo "    Updating existing record $RECORD_ID"
  curl -s -X PATCH \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${RECORD_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"content\":\"${TXT_CONTENT}\"}" | grep -o '"success":[a-z]*'
else
  echo "    Creating new record"
  curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"TXT\",\"name\":\"${TXT_NAME}\",\"content\":\"${TXT_CONTENT}\",\"ttl\":300}" | grep -o '"success":[a-z]*'
fi

echo ""
echo "==> Done. Verify:"
echo "    curl https://mta-sts.${DOMAIN}/.well-known/mta-sts.txt"
echo "    dig TXT ${TXT_NAME}"
