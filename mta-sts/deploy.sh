#!/usr/bin/env bash
# Harden DNS security for all domains in domains.conf:
#   - MTA-STS: deploy Cloudflare Worker + _mta-sts TXT record
#   - DMARC:   upsert _dmarc TXT to p=reject
#   - CAA:     add issue/issuewild/iodef records
#   - DNSSEC:  enable via Cloudflare API
#
# Usage:
#   ./deploy.sh                  # all domains in domains.conf
#   ./deploy.sh example.com      # one domain only
#
# Required:
#   CF_API_TOKEN in mta-sts/.env (or set in environment)
#
# Optional env vars:
#   MTA_STS_MODE    - testing|enforce (default: enforce)
#   MTA_STS_MAX_AGE - seconds (default: 86400)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

: "${CF_API_TOKEN:?set CF_API_TOKEN in mta-sts/.env}"

MODE="${MTA_STS_MODE:-enforce}"
MAX_AGE="${MTA_STS_MAX_AGE:-86400}"
FILTER="${1:-}"
DOMAINS_CONF="$SCRIPT_DIR/domains.conf"

[ -f "$DOMAINS_CONF" ] || { echo "ERROR: $DOMAINS_CONF not found" >&2; exit 1; }

# --- Helpers ---

cf_get() {
  curl -s --max-time 15 -X GET \
    "https://api.cloudflare.com/client/v4/$1" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json"
}

cf_post() {
  curl -s --max-time 15 -X POST \
    "https://api.cloudflare.com/client/v4/$1" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$2"
}

cf_patch() {
  curl -s --max-time 15 -X PATCH \
    "https://api.cloudflare.com/client/v4/$1" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$2"
}

# Get record ID for a given type+name (returns empty if not found)
get_record_id() {
  local ZONE_ID="$1" TYPE="$2" NAME="$3"
  cf_get "zones/${ZONE_ID}/dns_records?type=${TYPE}&name=${NAME}" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

upsert_txt() {
  local ZONE_ID="$1" NAME="$2" CONTENT="$3"
  local RECORD_ID
  RECORD_ID=$(get_record_id "$ZONE_ID" "TXT" "$NAME")
  if [ -n "$RECORD_ID" ]; then
    local RESULT
    RESULT=$(cf_patch "zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
      "{\"content\":\"${CONTENT}\"}")
    echo "$RESULT" | grep -o '"success":[a-z]*'
  else
    local RESULT
    RESULT=$(cf_post "zones/${ZONE_ID}/dns_records" \
      "{\"type\":\"TXT\",\"name\":\"${NAME}\",\"content\":\"${CONTENT}\",\"ttl\":300}")
    echo "$RESULT" | grep -o '"success":[a-z]*'
  fi
}

# --- MTA-STS ---

deploy_mta_sts() {
  local DOMAIN="$1" ZONE_ID="$2" MX_CSV="$3"
  local WORKER_NAME="mta-sts-${DOMAIN//./-}"
  local TIMESTAMP
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  local TMPDIR
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' RETURN

  local MX_LINES=""
  IFS=',' read -ra MX_ARRAY <<< "$MX_CSV"
  for mx in "${MX_ARRAY[@]}"; do
    MX_LINES+="mx: ${mx}"$'\n'
  done
  MX_LINES="${MX_LINES%$'\n'}"

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

  cat > "$TMPDIR/wrangler.toml" <<TOML
name = "${WORKER_NAME}"
main = "worker.js"
compatibility_date = "2024-09-23"

[[routes]]
pattern = "mta-sts.${DOMAIN}"
custom_domain = true
TOML

  echo "  [mta-sts] deploying worker ${WORKER_NAME}..."
  cd "$TMPDIR"
  CLOUDFLARE_API_TOKEN="$CF_API_TOKEN" wrangler deploy --config wrangler.toml 2>&1 \
    | grep -E '(Uploaded|Deployed|Current Version|error|Error)' || true
  cd "$SCRIPT_DIR"

  echo "  [mta-sts] upserting _mta-sts TXT..."
  local R
  R=$(upsert_txt "$ZONE_ID" "_mta-sts.${DOMAIN}" "v=STSv1; id=${TIMESTAMP}")
  echo "  [mta-sts] $R"
}

# --- DMARC ---

deploy_dmarc() {
  local DOMAIN="$1" ZONE_ID="$2"
  local NAME="_dmarc.${DOMAIN}"
  local RECORD_ID
  RECORD_ID=$(get_record_id "$ZONE_ID" "TXT" "$NAME")

  if [ -n "$RECORD_ID" ]; then
    # Check if already p=reject
    local EXISTING_CONTENT
    EXISTING_CONTENT=$(cf_get "zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
      | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
    if echo "$EXISTING_CONTENT" | grep -q 'p=reject'; then
      echo "  [dmarc] already p=reject, skipping"
      return
    fi
    echo "  [dmarc] escalating to p=reject (was: $EXISTING_CONTENT)..."
    local R
    R=$(cf_patch "zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
      "{\"content\":\"v=DMARC1; p=reject; rua=mailto:postmaster@${DOMAIN}\"}")
    echo "  [dmarc] $(echo "$R" | grep -o '"success":[a-z]*')"
  else
    echo "  [dmarc] creating p=reject record..."
    local R
    R=$(cf_post "zones/${ZONE_ID}/dns_records" \
      "{\"type\":\"TXT\",\"name\":\"${NAME}\",\"content\":\"v=DMARC1; p=reject; rua=mailto:postmaster@${DOMAIN}\",\"ttl\":300}")
    echo "  [dmarc] $(echo "$R" | grep -o '"success":[a-z]*')"
  fi
}

# --- CAA ---

deploy_caa() {
  local DOMAIN="$1" ZONE_ID="$2" CA="$3"

  # Fetch existing CAA records
  local EXISTING
  EXISTING=$(cf_get "zones/${ZONE_ID}/dns_records?type=CAA&name=${DOMAIN}")

  add_caa_if_missing() {
    local FLAG="$1" TAG="$2" VALUE="$3"
    if echo "$EXISTING" | grep -q "\"${TAG}\".*\"${VALUE}\""; then
      echo "  [caa] $TAG \"$VALUE\" already exists, skipping"
      return
    fi
    local R
    R=$(cf_post "zones/${ZONE_ID}/dns_records" \
      "{\"type\":\"CAA\",\"name\":\"${DOMAIN}\",\"data\":{\"flags\":${FLAG},\"tag\":\"${TAG}\",\"value\":\"${VALUE}\"},\"ttl\":300}")
    echo "  [caa] added $TAG \"$VALUE\": $(echo "$R" | grep -o '"success":[a-z]*')"
  }

  add_caa_if_missing 0 "issue" "$CA"
  add_caa_if_missing 0 "issuewild" ";"
  add_caa_if_missing 0 "iodef" "mailto:postmaster@${DOMAIN}"
}

# --- DNSSEC ---

deploy_dnssec() {
  local ZONE_ID="$1"
  local STATUS
  STATUS=$(cf_get "zones/${ZONE_ID}/dnssec" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ "$STATUS" = "active" ] || [ "$STATUS" = "pending" ]; then
    echo "  [dnssec] status=$STATUS, skipping"
    return
  fi
  echo "  [dnssec] enabling (currently: $STATUS)..."
  local R
  R=$(cf_patch "zones/${ZONE_ID}/dnssec" '{"status":"active"}')
  echo "  [dnssec] $(echo "$R" | grep -o '"status":"[^"]*"' | head -1)"
}

# --- Main loop ---

DEPLOYED=0
while IFS= read -r line; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
  IFS=':' read -r DOMAIN ZONE_ID MX_CSV CA <<< "$line"
  CA="${CA:-letsencrypt.org}"

  [ -n "$FILTER" ] && [ "$DOMAIN" != "$FILTER" ] && continue

  echo ""
  echo "========================================"
  echo "  $DOMAIN"
  echo "========================================"

  deploy_mta_sts "$DOMAIN" "$ZONE_ID" "$MX_CSV"
  deploy_dmarc   "$DOMAIN" "$ZONE_ID"
  deploy_caa     "$DOMAIN" "$ZONE_ID" "$CA"
  deploy_dnssec  "$ZONE_ID"

  echo "  --> done: $DOMAIN"
  DEPLOYED=$((DEPLOYED + 1))
done < "$DOMAINS_CONF"

if [ "$DEPLOYED" -eq 0 ]; then
  [ -n "$FILTER" ] && echo "ERROR: '$FILTER' not in domains.conf" >&2 || echo "ERROR: no domains in domains.conf" >&2
  exit 1
fi

echo ""
echo "All done. $DEPLOYED domain(s) hardened."
