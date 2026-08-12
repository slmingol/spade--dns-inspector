#!/usr/bin/env bash
# Deploy MTA-STS policy as a Cloudflare Worker for one or all domains in domains.conf.
#
# Usage:
#   ./deploy.sh                  # deploy all domains in domains.conf
#   ./deploy.sh example.com      # deploy one domain only
#
# Required:
#   CF_API_TOKEN in mta-sts/.env (or set in environment)
#   domains.conf in same directory as this script
#
# Optional env vars:
#   MTA_STS_MODE    - testing|enforce (default: enforce)
#   MTA_STS_MAX_AGE - seconds (default: 86400)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if present
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

: "${CF_API_TOKEN:?set CF_API_TOKEN in mta-sts/.env}"

MODE="${MTA_STS_MODE:-enforce}"
MAX_AGE="${MTA_STS_MAX_AGE:-86400}"
FILTER="${1:-}"  # optional: single domain to deploy
DOMAINS_CONF="$SCRIPT_DIR/domains.conf"

if [ ! -f "$DOMAINS_CONF" ]; then
  echo "ERROR: $DOMAINS_CONF not found" >&2
  exit 1
fi

deploy_domain() {
  local DOMAIN="$1"
  local ZONE_ID="$2"
  local MX_CSV="$3"

  local WORKER_NAME="mta-sts-${DOMAIN//./-}"
  local TIMESTAMP
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  local TMPDIR
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' RETURN

  # Build MX lines for policy file
  local MX_LINES=""
  IFS=',' read -ra MX_ARRAY <<< "$MX_CSV"
  for mx in "${MX_ARRAY[@]}"; do
    MX_LINES+="mx: ${mx}"$'\n'
  done
  MX_LINES="${MX_LINES%$'\n'}"

  echo ""
  echo "========================================"
  echo "  Domain:  $DOMAIN"
  echo "  Worker:  $WORKER_NAME"
  echo "  Mode:    $MODE"
  echo "  MX:      ${MX_CSV//,/ }"
  echo "========================================"

  # Generate worker.js
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

  # Generate wrangler.toml
  cat > "$TMPDIR/wrangler.toml" <<TOML
name = "${WORKER_NAME}"
main = "worker.js"
compatibility_date = "2024-09-23"

[[routes]]
pattern = "mta-sts.${DOMAIN}"
custom_domain = true
TOML

  # Deploy worker
  echo "--> Deploying worker..."
  cd "$TMPDIR"
  CLOUDFLARE_API_TOKEN="$CF_API_TOKEN" wrangler deploy --config wrangler.toml
  cd "$SCRIPT_DIR"

  # Upsert _mta-sts TXT record
  echo "--> Upserting _mta-sts TXT record..."
  local TXT_NAME="_mta-sts.${DOMAIN}"
  local TXT_CONTENT="v=STSv1; id=${TIMESTAMP}"

  local EXISTING
  EXISTING=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=TXT&name=${TXT_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  local RECORD_ID
  RECORD_ID=$(echo "$EXISTING" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ -n "$RECORD_ID" ]; then
    echo "    Updating existing record $RECORD_ID → $TXT_CONTENT"
    curl -s -X PATCH \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"content\":\"${TXT_CONTENT}\"}" | grep -o '"success":[a-z]*'
  else
    echo "    Creating record $TXT_CONTENT"
    curl -s -X POST \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"TXT\",\"name\":\"${TXT_NAME}\",\"content\":\"${TXT_CONTENT}\",\"ttl\":300}" | grep -o '"success":[a-z]*'
  fi

  echo "--> Done: $DOMAIN"
  echo "    curl https://mta-sts.${DOMAIN}/.well-known/mta-sts.txt"
}

# Read domains.conf and deploy
DEPLOYED=0
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

  IFS=':' read -r DOMAIN ZONE_ID MX_CSV <<< "$line"

  # Skip if filtering to a specific domain
  if [ -n "$FILTER" ] && [ "$DOMAIN" != "$FILTER" ]; then
    continue
  fi

  deploy_domain "$DOMAIN" "$ZONE_ID" "$MX_CSV"
  DEPLOYED=$((DEPLOYED + 1))
done < "$DOMAINS_CONF"

if [ "$DEPLOYED" -eq 0 ]; then
  if [ -n "$FILTER" ]; then
    echo "ERROR: domain '$FILTER' not found in domains.conf" >&2
  else
    echo "ERROR: no domains found in domains.conf" >&2
  fi
  exit 1
fi

echo ""
echo "All done. $DEPLOYED domain(s) deployed."
