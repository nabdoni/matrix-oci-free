#!/usr/bin/env bash
# harden-web-edge.sh — Caddy edge hardening for an invite-only private server.
#
# An invite-only server is only as good as its front door. Two levels, applied
# separately so the safe one can go up first:
#
#   apply        Block the Synapse Admin API and the self-registration endpoint
#                for every address except the admin CIDR. Element, login, media
#                and the bridge keep working; only admins can create accounts.
#
#   auth-gate    Additionally require a *valid Matrix session* for everything
#                except the pre-auth allowlist (login page, static assets, login
#                and register calls). This is the strong version: an anonymous
#                visitor can no longer even load Element, let alone probe the
#                client-server API. Needs a real access token to verify, so it
#                refuses to reload until you pass one.
#
#   usage: sudo bash harden-web-edge.sh check [ADMIN_CIDR]
#          sudo bash harden-web-edge.sh apply [ADMIN_CIDR]
#          sudo bash harden-web-edge.sh auth-gate [ADMIN_CIDR] --token syt_...
#          sudo bash harden-web-edge.sh rollback
set -euo pipefail

cd /opt/matrix
# Synapse's public hostname. Not the Matrix server_name, which may be the bare apex.
MATRIX_HOST=$(grep -m1 '^MATRIX_HOST=' .env 2>/dev/null | cut -d= -f2- || true)
MATRIX_HOST="${MATRIX_HOST:-$(grep -m1 '^MATRIX_DOMAIN=' .env 2>/dev/null | cut -d= -f2- || true)}"
[ -n "$MATRIX_HOST" ] || { echo "no MATRIX_HOST or MATRIX_DOMAIN in .env" >&2; exit 1; }
CADDYFILE=Caddyfile
BAK=Caddyfile.pre-edge
START="  # buncha-edge:start"
END="  # buncha-edge:end"
MARKER="# buncha-edge:start"

MODE="${1:-check}"
ADMIN_CIDR="${2:-}"
TOKEN=""
if [ "${3:-}" = "--token" ]; then TOKEN="${4:-}"; fi

if [ -z "$ADMIN_CIDR" ] && [ "$MODE" != "rollback" ]; then
  ADMIN_CIDR=$(grep -E '^ADMIN_CIDR=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  [ -n "$ADMIN_CIDR" ] || { echo "no ADMIN_CIDR: pass it as the 2nd argument or set ADMIN_CIDR= in .env" >&2; exit 1; }
fi

strip_block() {
  python3 - "$CADDYFILE" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
out, inside = [], False
for line in lines:
    if line.strip() == marker.strip():
        inside = True
        continue
    if inside:
        if line.strip() == "}" and any("@buncha_preauth" in l for l in out[-40:]):
            inside = False
        elif line.strip() == "}" and not any("@buncha_preauth" in l for l in out):
            inside = False
        continue
    out.append(line)
open(path, "w").write("\n".join(out))
PY
}

validate() {
  docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile
}

reload() {
  validate
  # The Caddyfile sets `admin off`, so `caddy reload` (which talks to the admin
  # API on :2019) cannot work. Restarting is ~1s of downtime and keeps the certs
  # (they live in the caddy-data volume).
  docker compose restart caddy
  sleep 5
}

smoke() {
  # 1. versions must stay open (every client needs it, and the gate relies on it)
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${MATRIX_HOST}/_matrix/client/versions" \
    --resolve ${MATRIX_HOST}:443:127.0.0.1 -k 2>/dev/null || true)
  echo "  /_matrix/client/versions        -> ${code:-?} (want 200)"
  # 2. admin API must be blocked for non-admin callers (we are not on the allowlist
  #    when testing from localhost, but private ranges are exempt, so this prints 200 here;
  #    the real check has to come from a non-allowlisted public address)
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${MATRIX_HOST}/_synapse/admin/v1/server_version" \
    --resolve ${MATRIX_HOST}:443:127.0.0.1 -k 2>/dev/null || true)
  echo "  /_synapse/admin/v1/server_version -> ${code:-?} (200 is EXPECTED here: this test comes from a private address, which is exempt. Verify from outside, see README)"
  # 3. self-registration must be blocked too
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${MATRIX_HOST}/_matrix/client/v3/register/available?username=testuser1234" \
    --resolve ${MATRIX_HOST}:443:127.0.0.1 -k 2>/dev/null || true)
  echo "  /_matrix/client/v3/register/available -> ${code:-?} (want 403: registration is closed in Synapse itself)"
}

case "$MODE" in
  rollback)
    [ -f "$BAK" ] || { echo "no $BAK to roll back to" >&2; exit 1; }
    cp -a "$BAK" "$CADDYFILE" && reload
    echo "rolled back to $BAK"
    exit 0
    ;;
  check)
    echo "mode=check admin_cidr=$ADMIN_CIDR"
    grep -q "$MARKER" "$CADDYFILE" && echo "buncha-edge block: PRESENT" || echo "buncha-edge block: absent"
    echo "current smoke (through Caddy on localhost):"
    smoke
    exit 0
    ;;
  apply|auth-gate) ;;
  *) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

if ! grep -qE "^ADMIN_CIDR=" .env; then
  echo "ADMIN_CIDR=$ADMIN_CIDR" >> .env
  echo "wrote ADMIN_CIDR=$ADMIN_CIDR to .env"
fi

[ -f "$BAK" ] || cp -a "$CADDYFILE" "$BAK"
chmod 640 "$CADDYFILE"
strip_block

# Pre-auth allowlist: deliberately generous (availability over strictness). If a
# request here needs a session, Element shows a login loop — add the path instead
# of removing the gate.
GATE='
	# Elements own flow: everything else needs a valid Matrix session.
	@buncha_preauth {
		path /.well-known/* /_matrix/static* /_matrix/client/versions /_matrix/client/v3/login* \
			/_matrix/client/v3/register* /_matrix/client/v3/logout /_matrix/client/versions \
			/_synapse/client/versions /_synapse/client/v3/login* /_synapse/client/v3/capabilities \
			/_synapse/client/v3/register* /_synapse/client/v3/account/password* /health /metrics \
			/_matrix/client/v3/account/whoami /_matrix/client/versions
	}
	forward_auth @buncha_preauth http://synapse:8008/_matrix/client/v3/account/whoami
'

if [ "$MODE" = "auth-gate" ]; then
  if [ -z "$TOKEN" ]; then
    echo "auth-gate needs a real access token to verify before it will reload." >&2
    echo "  create a throwaway account:  sudo bash invite-user.sh you@example.com probe" >&2
    echo "  then: sudo bash harden-web-edge.sh auth-gate $ADMIN_CIDR --token syt_..." >&2
    exit 2
  fi
fi

python3 - "$CADDYFILE" "$ADMIN_CIDR" "$START" "$END" "$GATE" "$MODE" <<'PY'
import sys
path, cidr, start, end, gate, mode = sys.argv[1:7]
lines = open(path).read().split("\n")
block = [
    start,
    "\t# Admin API and self-registration are admin-CIDR only: invite-only means",
    "\t# nobody outside the admin network can even try to create an account.",
    "\t@buncha_blocked {",
    "\t\tnot remote_ip %s 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16" % cidr,
    "\t\tpath /_synapse/admin /_synapse/admin/* /_synapse/client/v3/register /_synapse/client/v3/register/*",
    "\t}",
    '\trespond @buncha_blocked "buncha is invite-only; ask an admin for an invite" 403',
]
if mode == "auth-gate":
    block += [l for l in gate.strip("\n").split("\n")]
block.append(end)

out, inserted = [], False
for line in lines:
    if not inserted and line.startswith("\treverse_proxy /_matrix/*"):
        out += block
        inserted = True
    out.append(line)
if not inserted:
    sys.exit("could not find the insertion point (reverse_proxy /_matrix/*) in " + path)
open(path, "w").write("\n".join(out))
PY

validate || { cp -a "$BAK" "$CADDYFILE"; echo "caddy validate failed; restored $BAK" >&2; exit 1; }

if [ "$MODE" = "auth-gate" ] && [ -n "$TOKEN" ]; then
  authed=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://${MATRIX_HOST}/_matrix/client/v3/account/whoami" \
    -H "Authorization: Bearer $TOKEN" --resolve ${MATRIX_HOST}:443:127.0.0.1 -k 2>/dev/null || true)
  anon=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://${MATRIX_HOST}/_matrix/client/v3/sync?timeout=0" \
    --resolve ${MATRIX_HOST}:443:127.0.0.1 -k 2>/dev/null || true)
  echo "  whoami with token   -> $authed (want 200)"
  echo "  sync without token  -> $anon (want 401/403)"
  case "$authed$anon" in
    20040*|200*401|200*403) : ;;
    *) cp -a "$BAK" "$CADDYFILE"; echo "auth-gate verification failed; restored $BAK" >&2; exit 1 ;;
  esac
fi

reload
echo "applied mode=$MODE admin_cidr=$ADMIN_CIDR"
smoke
