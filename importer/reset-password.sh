#!/usr/bin/env bash
# reset-password.sh — set a new random password on an EXISTING account and print
# it once. The break-glass / "I forgot my password" tool.
#
#   usage: sudo bash reset-password.sh <localpart> [--logout]
#
# Uses the admin token cached by invite-user.sh / switch-domain.sh. By default
# the account's existing sessions stay logged in (so resetting the admin does
# not invalidate the cached token); pass --logout to sign every device out.
# Refuses if the account does not exist (the admin API would silently create it).
set -euo pipefail

usage() { sed -n '2,11p' "$0"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
LOCALPART="${1:-}"
[[ "$LOCALPART" =~ ^[a-z0-9._=-]+$ ]] || usage
LOGOUT=false
[ "${2:-}" = "--logout" ] && LOGOUT=true

cd /opt/matrix
TOKEN_CACHE=/root/.buncha-admin-token
[ -s "$TOKEN_CACHE" ] || { echo "no cached admin token at $TOKEN_CACHE" >&2; exit 1; }
MATRIX_DOMAIN=$(grep -m1 '^MATRIX_DOMAIN=' .env | cut -d= -f2-)
[ -n "$MATRIX_DOMAIN" ] || { echo "MATRIX_DOMAIN not set in .env" >&2; exit 1; }
USER_ID="@${LOCALPART}:${MATRIX_DOMAIN}"

PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | tr -dc 'A-Za-z0-9' | head -c 20)"!Aa1"

docker compose exec -T \
  -e TOK="$(cat "$TOKEN_CACHE")" -e USER_ID="$USER_ID" -e PW="$PASSWORD" -e LOGOUT="$LOGOUT" \
  synapse python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

base = "http://localhost:8008/_synapse/admin/v2/users/" + os.environ["USER_ID"]
hdr = {"Authorization": "Bearer " + os.environ["TOK"], "Content-Type": "application/json"}

# existence check first: PUT would create a brand-new account
req = urllib.request.Request(base, headers=hdr)
try:
    urllib.request.urlopen(req).read()
except urllib.error.HTTPError as e:
    if e.code == 404:
        sys.exit("refusing: %s does not exist. Nothing changed." % os.environ["USER_ID"])
    sys.exit("lookup failed: HTTP %s %s" % (e.code, e.read().decode()))

body = {"password": os.environ["PW"], "logout_devices": os.environ["LOGOUT"] == "true"}
req = urllib.request.Request(base, data=json.dumps(body).encode(), method="PUT", headers=hdr)
try:
    out = json.load(urllib.request.urlopen(req))
except urllib.error.HTTPError as e:
    sys.exit("Synapse refused: HTTP %s %s" % (e.code, e.read().decode()))
print("password updated for", out.get("name"), "admin=%s" % out.get("admin"))
PY

echo
echo "  account:   $USER_ID"
echo "  password:  $PASSWORD"
echo "  (shown once, stored nowhere; change it after logging in)"
