#!/usr/bin/env bash
# preflight.sh — Validate critical environment variables before running docker compose.
# Usage: bash scripts/preflight.sh
#
# Run this script any time you are about to do `docker compose up` to catch
# the most common self-hosting configuration mistakes early.

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

error() {
  echo -e "${RED}[ERROR]${NC} $1"
  ERRORS=$((ERRORS + 1))
}

warn() {
  echo -e "${YELLOW}[WARN] ${NC} $1"
  WARNINGS=$((WARNINGS + 1))
}

ok() {
  echo -e "${GREEN}[ OK ]${NC}  $1"
}

echo "============================================================"
echo " Fonoster self-hosted preflight check"
echo "============================================================"

# ── 1. .env file must exist ────────────────────────────────────
if [ ! -f .env ]; then
  error ".env file not found. Copy .env.example to .env and fill in the values."
  exit 1
fi

# shellcheck disable=SC1091
# Source .env safely: export only valid KEY=VALUE lines, ignoring comments and
# lines whose value contains unquoted spaces that would be misinterpreted by bash.
while IFS= read -r line || [ -n "$line" ]; do
  # Skip blank lines and comments
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  # Only export lines that look like KEY=VALUE (no leading spaces in key)
  if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    export "$line" 2>/dev/null || true
  fi
done < .env

# ── 2. Required IP / address variables ────────────────────────
#
# These three must all be set to the same reachable IP address.
# Any one being wrong (or left as a placeholder) will cause RTP
# audio to fail silently even though the SIP call connects.

PLACEHOLDER_PATTERN='^/\*.*\*/$'  # matches /* ... */

check_ip_var() {
  local var_name="$1"
  local var_value="${!var_name:-}"

  if [ -z "$var_value" ] || [[ "$var_value" =~ $PLACEHOLDER_PATTERN ]]; then
    error "$var_name is not set. Set it to the public IP (or LAN IP for local) of this host."
  else
    ok "$var_name = $var_value"
  fi
}

check_ip_var ROUTR_EXTERNAL_ADDRS
check_ip_var ASTERISK_SIPPROXY_HOST
check_ip_var RTPENGINE_PUBLIC_IP

# Warn if the three IP vars are not identical (common misconfiguration)
if [ -n "${ROUTR_EXTERNAL_ADDRS:-}" ] && \
   [ -n "${ASTERISK_SIPPROXY_HOST:-}" ] && \
   [ -n "${RTPENGINE_PUBLIC_IP:-}" ]; then
  if [ "$ROUTR_EXTERNAL_ADDRS" != "$ASTERISK_SIPPROXY_HOST" ] || \
     [ "$ROUTR_EXTERNAL_ADDRS" != "$RTPENGINE_PUBLIC_IP" ]; then
    warn "ROUTR_EXTERNAL_ADDRS, ASTERISK_SIPPROXY_HOST and RTPENGINE_PUBLIC_IP should normally be the same IP address. Verify this is intentional."
  else
    ok "All three RTP/SIP IP variables are consistent."
  fi
fi

# ── 3. Secrets must not be left as 'changeme' in production ───
check_secret() {
  local var_name="$1"
  local var_value="${!var_name:-}"
  if [ -z "$var_value" ]; then
    error "$var_name is not set."
  elif [ "$var_value" = "changeme" ]; then
    warn "$var_name is still set to the default 'changeme'. Change it before exposing this service publicly."
  else
    ok "$var_name is set."
  fi
}

check_secret ASTERISK_SIPPROXY_SECRET
check_secret ASTERISK_ARI_SECRET
check_secret APISERVER_ASTERISK_ARI_SECRET
check_secret APISERVER_OWNER_PASSWORD
check_secret POSTGRES_PASSWORD

# ── 4. integrations.json must exist ───────────────────────────
if [ ! -f config/integrations.json ]; then
  error "config/integrations.json not found. Copy config/integrations.example.json to config/integrations.json and add your API credentials."
else
  ok "config/integrations.json exists."
fi

# ── 5. RSA key pair must exist ────────────────────────────────
if [ ! -f config/keys/private.pem ] || [ ! -f config/keys/public.pem ]; then
  error "config/keys/private.pem or config/keys/public.pem not found. Run: openssl genpkey -algorithm rsa -out config/keys/private.pem -pkeyopt rsa_keygen_bits:2048 && openssl rsa -in config/keys/private.pem -pubout -out config/keys/public.pem"
else
  ok "RSA key pair found in config/keys/."
fi

# ── 6. APISERVER_CLOAK_ENCRYPTION_KEY should not be default ───
DEFAULT_CLOAK="k1.aesgcm256.MmPSvzCG9fk654bAbl30tsqq4h9d3N4F11hlue8bGAY="
if [ "${APISERVER_CLOAK_ENCRYPTION_KEY:-}" = "$DEFAULT_CLOAK" ]; then
  warn "APISERVER_CLOAK_ENCRYPTION_KEY is still set to the example value. Generate a new one with: docker run --rm fonoster/apiserver:0.17.1 cloak-key"
else
  ok "APISERVER_CLOAK_ENCRYPTION_KEY is customized."
fi

# ── 7. Summary ────────────────────────────────────────────────
echo ""
echo "============================================================"
if [ "$ERRORS" -gt 0 ]; then
  echo -e "${RED}Preflight FAILED: $ERRORS error(s), $WARNINGS warning(s).${NC}"
  echo "Fix the errors above before running 'docker compose up'."
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  echo -e "${YELLOW}Preflight passed with $WARNINGS warning(s). Review the warnings above.${NC}"
else
  echo -e "${GREEN}Preflight passed! You are ready to run 'docker compose up'.${NC}"
fi
echo "============================================================"
