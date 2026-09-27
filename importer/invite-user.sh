#!/usr/bin/env bash
# invite-user.sh — invite-only account creation for a private buncha server.
#
# There is no sign-up. Element's "Create account" is dead because Synapse runs
# with enable_registration: false. The only way an account comes into existence is
# this script, which uses the Synapse **Admin API** (a bearer token that never
# leaves the box) and hands out one random 24-character password.
#
#   usage: sudo bash invite-user.sh EMAIL [LOCALPART] [--admin] [--no-log-secret]
#          sudo bash invite-user.sh me@example.com nabil --admin
#
# The password is printed exactly once and is not written to the invite log.
# If msmtp is configured on the box the credentials are emailed; otherwise print
# them and send them yourself. The invitee should change the password in Element
# after first login (Synapse has no forced-change, which is why the generated
# password is long and single-use).
set -euo pipefail

COMPOSE_DIR=/opt/matrix
TOKEN_CACHE=/root/.buncha-admin-token
INVITE_LOG=/var/log/buncha-invites.log

usage() { sed -n '2,20p' "$0"; exit 1; }
[ $# -ge 1 ] || usage

EMAIL=""
LOCALPART=""
ADMIN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --admin)   ADMIN=true ;;
    --no-log-secret) : ;;
    -h|--help) usage ;;
    *)
      if [ -z "$EMAIL" ]; then EMAIL="$1"
      elif [ -z "$LOCALPART" ]; then LOCALPART="$1"
      else echo "unexpected argument: $1" >&2; usage
      fi
      ;;
  esac
  shift
done

case "$EMAIL" in
  *@*.*) ;;
  *) echo "EMAIL must look like an address (got '$EMAIL')" >&2; exit 1 ;;
esac

if [ -z "$LOCALPART" ]; then
  LOCALPART=$(printf '%s' "${EMAIL%%@*}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._=-')
  # Synapse wants a specific shape; strip what it dislikes and pad if it empties out.
  LOCALPART=$(printf '%s' "$LOCALPART" | sed -E 's/[^a-z0-9._=-]//g; s/^[^a-z0-9]+//; s/[^a-z0-9]+$//')
  [ -n "$LOCALPART" ] || LOCALPART="user$(date -u +%s)"
fi

if ! printf '%s' "$LOCALPART" | grep -qE '^[a-z0-9._=-]{1,255}$'; then
  echo "LOCALPART must match ^[a-z0-9._=-]{1,255}$ (got '$LOCALPART')" >&2
  exit 1
fi

cd "$COMPOSE_DIR"

# Synapse's client/admin API is never published to the host — Caddy reaches it
# internally as synapse:8008 on the compose network only (see cloud-init.yaml),
# and that hostname doesn't resolve from outside the container either. So we
# reach it by execing into the synapse container and hitting its own loopback,
# which sidesteps the docker network entirely. (There is no token to scrape out
# of the synapse logs — plain Synapse never prints one on boot; that was wrong.)
call_synapse() {
  local method="$1" path="$2" body="${3:-}" token="${4:-}"
  docker compose exec -T synapse python3 - "$method" "$path" "$body" "$token" <<'PY'
import sys, urllib.request, urllib.error
method, path, body, token = sys.argv[1:5]
headers = {"Content-Type": "application/json"}
if token:
    headers["Authorization"] = "Bearer " + token
req = urllib.request.Request(
    "http://localhost:8008" + path,
    data=body.encode() if body else None,
    method=method,
    headers=headers,
)
try:
    sys.stdout.write(urllib.request.urlopen(req).read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
PY
}

if [ -z "${SYNAPSE_ADMIN_TOKEN:-}" ] && [ ! -s "$TOKEN_CACHE" ]; then
  echo "no admin token cached; pass SYNAPSE_ADMIN_TOKEN=syt_... (log in as an" >&2
  echo "existing admin via /_matrix/client/v3/login to get one)" >&2
  exit 1
fi
[ -n "${SYNAPSE_ADMIN_TOKEN:-}" ] || SYNAPSE_ADMIN_TOKEN=$(cat "$TOKEN_CACHE")

PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | tr -dc 'A-Za-z0-9' | head -c 20)"!Aa1"
[ "${#PASSWORD}" -ge 20 ] || { echo "password generation failed" >&2; exit 1; }

MATRIX_DOMAIN=$(grep -m1 '^MATRIX_DOMAIN=' .env 2>/dev/null | cut -d= -f2-)
[ -n "$MATRIX_DOMAIN" ] || { echo "MATRIX_DOMAIN not set in $COMPOSE_DIR/.env" >&2; exit 1; }
USER_ID="@${LOCALPART}:${MATRIX_DOMAIN}"

DISPLAYNAME="$EMAIL"
# v2/users PUT creates-or-updates: an existing account here would silently take
# on this new password/admin flag instead of refusing, so check first.
EXISTING=$(call_synapse GET "/_synapse/admin/v2/users/$USER_ID" "" "$SYNAPSE_ADMIN_TOKEN")
if ! printf '%s' "$EXISTING" | grep -q '"errcode"[[:space:]]*:[[:space:]]*"M_NOT_FOUND"'; then
  echo "refusing: $LOCALPART already exists. Nothing changed." >&2
  exit 1
fi

PAYLOAD=$(printf '{"password":"%s","displayname":"%s","admin":%s}' \
  "$PASSWORD" "$DISPLAYNAME" "$ADMIN")

RESP=$(call_synapse PUT "/_synapse/admin/v2/users/$USER_ID" "$PAYLOAD" "$SYNAPSE_ADMIN_TOKEN")
[ -s "$TOKEN_CACHE" ] || { printf '%s' "$SYNAPSE_ADMIN_TOKEN" > "$TOKEN_CACHE"; chmod 600 "$TOKEN_CACHE"; }

if printf '%s' "$RESP" | grep -q '"errcode"'; then
  ERR=$(printf '%s' "$RESP" | sed -E 's/.*"error"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  echo "Synapse refused the invite: $ERR" >&2
  echo "$RESP" >> "$INVITE_LOG"
  exit 1
fi

USER_ID=$(printf '%s' "$RESP" | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
[ -n "$USER_ID" ] || { echo "unexpected response: $RESP" >&2; exit 1; }

# Log the fact, never the secret.
printf '%s invited=%s user_id=%s admin=%s\n' \
  "$(date -u +%FT%TZ)" "$EMAIL" "$USER_ID" "$ADMIN" >> "$INVITE_LOG"

cat <<EOF

Invite created
  Matrix ID : $USER_ID
  Email     : $EMAIL
  Admin     : $ADMIN
  Password  : $PASSWORD     <-- shown once, not logged

Send these to $EMAIL, then ask them to change the password in Element
(Settings -> Security -> Change password) and to enable 2FA (MSC3884 /
Element -> Settings -> Security) if the client offers it.
EOF

if command -v msmtp >/dev/null 2>&1; then
  printf 'To: %s\nSubject: Your buncha Matrix account\n\nMatrix ID: %s\nTemporary password: %s\n\nPlease change it after first login.\n' \
    "$EMAIL" "$USER_ID" "$PASSWORD" | msmtp --account=default "$EMAIL" \
    && echo "emailed to $EMAIL via msmtp" || echo "msmtp failed; send the details manually"
else
  echo "(no msmtp on this box: send the details to $EMAIL yourself, or configure SMTP)"
fi
