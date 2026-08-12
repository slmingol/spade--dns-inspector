#!/usr/bin/env bash
# DNS security status summary for all domains in domains.conf.
# Queries Cloudflare DNS directly (1.1.1.1) — no dependency on Spade UI.
#
# Usage:
#   ./mta-sts/check-all.sh
#   ./mta-sts/check-all.sh example.com   # single domain

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_CONF="$SCRIPT_DIR/domains.conf"
NS="1.1.1.1"
FILTER="${1:-}"

# ANSI colors
GRN='\033[0;32m'; YLW='\033[0;33m'; RED='\033[0;31m'; DIM='\033[2m'; RST='\033[0m'
PASS="${GRN}PASS${RST}"; WARN="${YLW}WARN${RST}"; FAIL="${RED}FAIL${RST}"

check_spf() {
  local DOMAIN="$1"
  local REC
  REC=$(dig TXT "$DOMAIN" @"$NS" +short 2>/dev/null | grep 'v=spf1' | tr -d '"' || true)
  if [ -z "$REC" ]; then echo -e "$FAIL"; return; fi
  if echo "$REC" | grep -q '\-all'; then echo -e "$PASS"
  elif echo "$REC" | grep -q '~all'; then echo -e "$WARN"
  else echo -e "$WARN"; fi
}

check_dmarc() {
  local DOMAIN="$1"
  local REC
  REC=$(dig TXT "_dmarc.$DOMAIN" @"$NS" +short 2>/dev/null | grep 'v=DMARC1' | tr -d '"' || true)
  if [ -z "$REC" ]; then echo -e "$FAIL"; return; fi
  if echo "$REC" | grep -q 'p=reject'; then echo -e "$PASS"
  elif echo "$REC" | grep -qE 'p=quarantine|p=none'; then echo -e "$WARN"
  else echo -e "$WARN"; fi
}

check_caa() {
  local DOMAIN="$1"
  local REC
  REC=$(dig CAA "$DOMAIN" @"$NS" +short 2>/dev/null || true)
  if [ -z "$REC" ]; then echo -e "$WARN"; return; fi
  echo -e "$PASS"
}

check_dnssec() {
  local DOMAIN="$1"
  # Query DS record — existence means DNSSEC is configured at registrar
  local DS
  DS=$(dig DS "$DOMAIN" @"$NS" +short 2>/dev/null || true)
  if [ -z "$DS" ]; then
    # Check if zone is signed (DNSKEY present)
    local DNSKEY
    DNSKEY=$(dig DNSKEY "$DOMAIN" @"$NS" +short 2>/dev/null || true)
    if [ -n "$DNSKEY" ]; then echo -e "$WARN"  # signed but no DS
    else echo -e "$FAIL"; fi
    return
  fi
  # DS exists — check AD flag with validating resolver
  local AD
  AD=$(dig A "$DOMAIN" @"$NS" +dnssec 2>/dev/null | grep -c 'flags:.*ad' || true)
  if [ "$AD" -gt 0 ]; then echo -e "$PASS"
  else echo -e "$WARN"; fi
}

check_mta_sts() {
  local DOMAIN="$1"
  local TXT
  TXT=$(dig TXT "_mta-sts.$DOMAIN" @"$NS" +short 2>/dev/null | grep 'v=STSv1' | tr -d '"' || true)
  if [ -z "$TXT" ]; then echo -e "$FAIL"; return; fi
  local POLICY
  POLICY=$(curl -sf --max-time 5 "https://mta-sts.$DOMAIN/.well-known/mta-sts.txt" 2>/dev/null || true)
  if [ -z "$POLICY" ]; then echo -e "$WARN"; return; fi
  if echo "$POLICY" | grep -q 'mode: enforce'; then echo -e "$PASS"
  elif echo "$POLICY" | grep -q 'mode: testing'; then echo -e "$WARN"
  else echo -e "$FAIL"; fi
}

check_dkim() {
  local DOMAIN="$1"
  local SELECTORS="dkim google default mail smtp s1 s2 k1 selector1 selector2 \
    mxvault mandrill mailjet sendgrid smtp2 pm zoho protonmail"
  for SEL in $SELECTORS; do
    local REC
    REC=$(dig TXT "${SEL}._domainkey.$DOMAIN" @"$NS" +short 2>/dev/null | grep -i 'v=DKIM1' || true)
    if [ -n "$REC" ]; then echo -e "$PASS ($SEL)"; return; fi
  done
  echo -e "$FAIL"
}

# Header
printf "\n%-20s  %-6s  %-6s  %-6s  %-6s  %-6s  %-6s\n" \
  "DOMAIN" "SPF" "DMARC" "CAA" "DNSSEC" "MTA-STS" "DKIM"
printf '%s\n' "$(printf '%.0s-' {1..80})"

while IFS= read -r line; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
  IFS=':' read -r DOMAIN ZONE_ID MX_CSV CA <<< "$line"
  [ -n "$FILTER" ] && [ "$DOMAIN" != "$FILTER" ] && continue

  SPF=$(check_spf "$DOMAIN")
  DMARC=$(check_dmarc "$DOMAIN")
  CAA=$(check_caa "$DOMAIN")
  DNSSEC=$(check_dnssec "$DOMAIN")
  MTA=$(check_mta_sts "$DOMAIN")
  DKIM=$(check_dkim "$DOMAIN")

  printf "%-20s  %-15b  %-15b  %-15b  %-15b  %-15b  %-15b\n" \
    "$DOMAIN" "$SPF" "$DMARC" "$CAA" "$DNSSEC" "$MTA" "$DKIM"
done < "$DOMAINS_CONF"

echo ""
