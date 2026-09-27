#!/usr/bin/env bash
# switch-domain.sh — move buncha from the placeholder names to a real domain.
#
# Matrix's server_name is baked into every user ID and cannot be renamed in
# place, so this WIPES the Synapse and bridge databases and rebuilds them under
# the new name. It is only safe while the server holds nothing worth keeping
# (no imported history). It refuses if it finds real data, and it always takes
# a backup first.
#
# Layout after the switch (apex = your domain, e.g. shovelwatch.com):
#   @nabil:<apex>          Matrix IDs use the bare domain
#   https://chat.<apex>    Element web (what people open / bookmark)
#   https://matrix.<apex>  Synapse (the homeserver API)
#   https://<apex>         serves /.well-known/matrix/client so mobile apps can
#                          be pointed at just "<apex>", and redirects to chat.
#   https://livekit.<apex> LiveKit signalling
#
#   usage: sudo bash switch-domain.sh <apex>              # dry run: checks + plan
#          sudo bash switch-domain.sh <apex> --yes-wipe   # do it
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

APEX="${1:-}"
CONFIRM="${2:-}"
[ -n "$APEX" ] || { sed -n '2,24p' "$0"; exit 1; }
[[ "$APEX" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
  || die "'$APEX' is not a bare lowercase domain like example.com"
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

DIR="$(cd "$(dirname "$0")" && pwd)"
MATRIX_HOST="matrix.$APEX"
ELEMENT_HOST="chat.$APEX"
LIVEKIT_HOST="livekit.$APEX"
cd /opt/matrix

psqlc() { docker compose exec -T postgres psql -U synapse -d "$1" -Atqc "$2"; }

echo "== 1. DNS: all four names must point at this VM =="
PUBLIC_IP=$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)
[ -n "$PUBLIC_IP" ] || die "could not determine this VM's public IP"
echo "  this VM: $PUBLIC_IP"
bad=0
for h in "$APEX" "$MATRIX_HOST" "$ELEMENT_HOST" "$LIVEKIT_HOST"; do
  got=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [ "$got" = "$PUBLIC_IP " ]; then
    printf '  ok   %-32s %s\n' "$h" "$PUBLIC_IP"
  else
    printf '  BAD  %-32s -> %s\n' "$h" "${got:-<no record>}"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || die "fix the A records first (DNS only / grey cloud, no AAAA), wait a few minutes, retry"

echo "== 2. what would be wiped =="
USERS=$(psqlc synapse 'select count(*) from users' 2>/dev/null || echo '?')
ROOMS=$(psqlc synapse 'select count(*) from rooms' 2>/dev/null || echo '?')
EVENTS=$(psqlc synapse 'select count(*) from events' 2>/dev/null || echo '?')
MEDIA=$(du -sh synapse/media_store 2>/dev/null | cut -f1 || true)
echo "  users=$USERS rooms=$ROOMS events=$EVENTS media=${MEDIA:-0}"
if [[ "$EVENTS" =~ ^[0-9]+$ ]] && [ "$EVENTS" -gt 2000 ] && [ "${BUNCHA_I_KNOW_THIS_WIPES_HISTORY:-}" != "1" ]; then
  die "$EVENTS events is real history, not test data. Refusing. (Override: BUNCHA_I_KNOW_THIS_WIPES_HISTORY=1)"
fi

if [ "$CONFIRM" != "--yes-wipe" ]; then
  echo
  echo "Dry run only. Everything above checked out. To proceed:"
  echo "  sudo bash $0 $APEX --yes-wipe"
  exit 0
fi

echo "== 3. backup =="
TS=$(date -u +%Y%m%dT%H%M%SZ)
BK=/var/backups/buncha/pre-switch-$TS
install -d -m 700 "$BK"
docker compose exec -T postgres pg_dump -U synapse synapse | gzip > "$BK/synapse.sql.gz"
docker compose exec -T postgres pg_dump -U synapse discord 2>/dev/null | gzip > "$BK/discord.sql.gz" || true
[ -s "$BK/synapse.sql.gz" ] || die "synapse dump is empty; not continuing"
for f in .env docker-compose.yml Caddyfile element/config.json mautrix-discord/config.yaml \
         synapse/homeserver.yaml synapse/*.signing.key; do
  [ -f "$f" ] && cp -a "$f" "$BK/$(echo "$f" | tr / _)"
done
chmod -R go-rwx "$BK"
echo "  saved to $BK"

echo "== 4. stop synapse, bridge and caddy =="
docker compose stop synapse mautrix-discord caddy

echo "== 5. .env =="
[ -z "$(tail -c1 .env)" ] || echo >> .env
setenv() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi
}
setenv MATRIX_DOMAIN "$APEX"          # the Matrix server_name
setenv MATRIX_HOST "$MATRIX_HOST"     # where Synapse is reachable
setenv ELEMENT_DOMAIN "$ELEMENT_HOST"
setenv LIVEKIT_DOMAIN "$LIVEKIT_HOST"
chmod 600 .env

echo "== 6. recreate databases =="
docker compose exec -T postgres psql -U synapse -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('synapse','discord') AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS synapse;
DROP DATABASE IF EXISTS discord;
CREATE DATABASE synapse OWNER synapse ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0;
CREATE DATABASE discord OWNER synapse ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0;
SQL

echo "== 7. synapse config =="
HS=synapse/homeserver.yaml
sed -i "s|^server_name:.*|server_name: \"$APEX\"|" "$HS"
grep -q "^server_name: \"$APEX\"" "$HS" || die "server_name edit did not take"
if grep -q '^public_baseurl:' "$HS"; then
  sed -i "s|^public_baseurl:.*|public_baseurl: \"https://$MATRIX_HOST/\"|" "$HS"
else
  printf '\npublic_baseurl: "https://%s/"\n' "$MATRIX_HOST" >> "$HS"
fi
[ -d synapse/media_store ] && find synapse/media_store -mindepth 1 -delete
if grep -n 'example\.com' "$HS"; then echo "  WARNING: old placeholder still referenced above" >&2; fi

echo "== 8. element config =="
python3 - "$MATRIX_HOST" "$APEX" "$LIVEKIT_HOST" <<'PY'
import json, sys
host, apex, lk = sys.argv[1:4]
p = "element/config.json"
c = json.load(open(p))
hs = c.setdefault("default_server_config", {}).setdefault("m.homeserver", {})
hs["base_url"] = "https://" + host
hs["server_name"] = apex
if "livekit" in c:
    c["livekit"]["url"] = "wss://" + lk
json.dump(c, open(p, "w"), indent=2)
PY
chmod 644 element/config.json

echo "== 9. caddy =="
cat > Caddyfile <<'CADDY'
{
	admin off
}

@@APEX@@ {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}
	# Lets a mobile app be pointed at just "@@APEX@@" and find the homeserver.
	handle /.well-known/matrix/client {
		header Access-Control-Allow-Origin "*"
		header Content-Type "application/json"
		respond `{"m.homeserver":{"base_url":"https://@@MATRIX_HOST@@"}}` 200
	}
	handle {
		redir https://@@ELEMENT_HOST@@{uri} permanent
	}
}

@@MATRIX_HOST@@ {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		Content-Security-Policy "frame-ancestors 'none'"
		-Server
	}
	reverse_proxy /_matrix/* synapse:8008
	reverse_proxy /_synapse/client/* synapse:8008
}

@@ELEMENT_HOST@@ {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}
	reverse_proxy element:80
}

@@LIVEKIT_HOST@@ {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		-Server
	}
	reverse_proxy host.docker.internal:7880
}
CADDY
sed -i "s|@@APEX@@|$APEX|g; s|@@MATRIX_HOST@@|$MATRIX_HOST|g; s|@@ELEMENT_HOST@@|$ELEMENT_HOST|g; s|@@LIVEKIT_HOST@@|$LIVEKIT_HOST|g" Caddyfile

echo "== 10. discord bridge config + registration =="
CFG=mautrix-discord/config.yaml
sed -i "s|@admin:matrix\.example\.com|@nabil:$APEX|g; s|matrix\.example\.com|$APEX|g" "$CFG"
if grep -n 'example\.com' "$CFG"; then echo "  WARNING: old placeholder still referenced above" >&2; fi
# fresh appservice tokens, written into the config, registration regenerated from it
AS=$(openssl rand -hex 32); HSTOK=$(openssl rand -hex 32)
python3 - "$AS" "$HSTOK" <<'PY'
import re, sys
as_token, hs_token = sys.argv[1], sys.argv[2]
p = "mautrix-discord/config.yaml"
s = open(p).read()
s = re.sub(r"^\s*(id|as_token|hs_token):.*\n", "", s, flags=re.M)
s = s.replace("appservice:\n",
              "appservice:\n    id: discord\n    as_token: %s\n    hs_token: %s\n" % (as_token, hs_token), 1)
open(p, "w").write(s)
PY
rm -f mautrix-discord/discord-registration.yaml
docker compose run --rm --entrypoint /usr/bin/mautrix-discord mautrix-discord \
  -g -c /data/config.yaml -r /data/discord-registration.yaml
cp mautrix-discord/discord-registration.yaml synapse/discord-registration.yaml
chmod 0644 synapse/discord-registration.yaml

echo "== 11. start synapse =="
docker compose up -d synapse
ok=0
for _ in $(seq 1 40); do
  if docker compose exec -T synapse python3 -c \
     "import urllib.request; urllib.request.urlopen('http://localhost:8008/health')" >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 3
done
[ "$ok" -eq 1 ] || { docker compose logs --tail 30 synapse; die "synapse did not come up"; }

echo "== 12. first admin: nabil =="
PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | tr -dc 'A-Za-z0-9' | head -c 20)"!Aa1"
docker compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml \
  -u nabil -p "$PASSWORD" -a http://localhost:8008 >/dev/null
TOKEN=$(docker compose exec -T -e PW="$PASSWORD" synapse python3 - <<'PY'
import json, os, urllib.request
req = urllib.request.Request(
    "http://localhost:8008/_matrix/client/v3/login",
    data=json.dumps({"type": "m.login.password",
                     "identifier": {"type": "m.id.user", "user": "nabil"},
                     "password": os.environ["PW"],
                     "initial_device_display_name": "buncha admin tooling"}).encode(),
    headers={"Content-Type": "application/json"}, method="POST")
print(json.load(urllib.request.urlopen(req))["access_token"])
PY
)
[ -n "$TOKEN" ] || die "login as nabil failed"
( umask 077; printf '%s' "$TOKEN" > /root/.buncha-admin-token )
echo "  nabil created and can log in; admin token cached for invite-user.sh"
# Show the password NOW, not only at the very end: if a later step fails the
# account must not be left with a password nobody has seen.
echo "  >>> @nabil:$APEX  password: $PASSWORD   (shown once; also repeated at the end)"

echo "== 13. start everything else =="
docker compose up -d --force-recreate element caddy mautrix-discord

echo "== 14. real TLS certificates (Let's Encrypt, up to ~2 min) =="
check() { # host path
  curl -fsS -o /dev/null --max-time 8 --resolve "$1:443:127.0.0.1" "https://$1$2" 2>/dev/null
}
for spec in "$MATRIX_HOST:/_matrix/client/versions" "$ELEMENT_HOST:/" "$APEX:/.well-known/matrix/client"; do
  h=${spec%%:*}; p=${spec#*:}; got=0
  for _ in $(seq 1 24); do check "$h" "$p" && { got=1; break; }; sleep 5; done
  if [ "$got" -eq 1 ]; then echo "  ok   https://$h$p"; else echo "  FAIL https://$h$p (see: docker compose logs caddy)"; fi
done

echo "== 15. tooling + hardening =="
if [ -f "$DIR/invite-user.sh" ]; then install -m 755 "$DIR/invite-user.sh" /usr/local/bin/invite-user.sh; fi
# Hardening failures must not stop the credentials box below from printing.
if [ -f "$DIR/harden-identity.sh" ]; then
  bash "$DIR/harden-identity.sh" >/dev/null && echo "  identity hardening re-applied" \
    || echo "  WARNING: harden-identity.sh failed; re-run it by hand" >&2
fi
if [ -f "$DIR/harden-web-edge.sh" ]; then
  bash "$DIR/harden-web-edge.sh" apply \
    || echo "  WARNING: harden-web-edge.sh failed; re-run: sudo bash $DIR/harden-web-edge.sh apply" >&2
fi

docker compose ps --format '{{.Service}}: {{.Status}}'

cat <<EOF

=====================================================================
 DONE.  Backup of the old state: $BK

 Element web:   https://$ELEMENT_HOST
 Mobile app:    homeserver "$APEX"
 Admin login:   nabil   (Matrix ID @nabil:$APEX)
 Password:      $PASSWORD

 The password is shown ONCE and stored nowhere. Log in and change it
 (Settings -> Security & Privacy). Invite people with:
   sudo bash /usr/local/bin/invite-user.sh their@email.com theirname
=====================================================================
EOF
