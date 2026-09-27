#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix
set -a
. ./.env
set +a

echo "== 1. appservice registration permissions =="
[ -f synapse/discord-registration.yaml ] && chmod 0644 synapse/discord-registration.yaml || echo "(no registration yet, skipping)"
docker compose restart synapse

echo "== 2. livekit: valid rtc keys + rotated secrets =="
if ! grep -q LIVEKIT_DEVKEY .env; then
  printf 'LIVEKIT_DEVKEY=%s\nLIVEKIT_SECRET=%s\n' "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" >> .env
  set -a; . ./.env; set +a
fi
cat > livekit.yaml <<EOF
port: 7880
bind_addresses:
  - "0.0.0.0"
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true
keys:
  devkey: "${LIVEKIT_DEVKEY}"
  secret: "${LIVEKIT_SECRET}"
EOF
chmod 0600 livekit.yaml
docker compose up -d livekit

echo "== 3. element config (hardened + livekit) =="
mkdir -p element
python3 - <<'PY'
import json, os
cfg = {
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://" + os.environ["MATRIX_DOMAIN"],
            "server_name": os.environ["MATRIX_DOMAIN"],
        }
    },
    "brand": "buncha",
    "disable_guests": True,
    "show_labs_settings": True,
    "livekit": {
        "url": "wss://" + os.environ["LIVEKIT_DOMAIN"],
        "devKey": os.environ["LIVEKIT_DEVKEY"],
    },
}
with open("element/config.json", "w") as f:
    json.dump(cfg, f, indent=2)
PY
chmod 0644 element/config.json
docker compose up -d --force-recreate element

echo "== 4. synapse: registration stays closed =="
sed -i 's/^enable_registration: .*/enable_registration: False/' synapse/homeserver.yaml
docker compose restart synapse

echo "== 5. ufw: default deny + explicit media rules =="
DEBIAN_FRONTEND=noninteractive apt-get install -y -q ufw > /dev/null
ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3478/udp
ufw allow 3478/tcp
ufw allow 7881/tcp
ufw allow 50000:60000/udp
ufw --force enable
ufw status | head -15

echo "== 6. caddy security headers =="
cat > Caddyfile <<'CADDY'
{
	admin off
}

{$MATRIX_DOMAIN} {
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

{$ELEMENT_DOMAIN} {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}
	reverse_proxy element:80
}

{$LIVEKIT_DOMAIN} {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		-Server
	}
	reverse_proxy host.docker.internal:7880
}
CADDY
docker compose up -d caddy
docker compose restart caddy

echo "== 7. final state =="
sleep 12
docker compose ps --format '{{.Service}}: {{.Status}}'
echo "--- livekit ---"
docker compose logs --tail 3 livekit
echo "--- synapse ---"
docker compose logs --tail 3 synapse
echo "--- bridge ---"
docker compose logs --tail 3 mautrix-discord
echo "--- fail2ban ---"
fail2ban-client status sshd || true
echo "--- sshd ---"
grep -E '^(PasswordAuthentication|PermitRootLogin)' /etc/ssh/sshd_config
