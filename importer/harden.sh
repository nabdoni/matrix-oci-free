#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix
set -a
. ./.env
set +a

echo "== 1. bridge: correct registry + full configure =="
sed -i 's|image: ghcr.io/mautrix/discord:latest|image: dock.mau.dev/mautrix/discord:latest|; s|image: mautrix/discord:latest|image: dock.mau.dev/mautrix/discord:latest|' docker-compose.yml
BRIDGE_SCRIPT=""
for candidate in /tmp/importer/configure-bridge.sh /tmp/configure-bridge.sh; do
  [ -f "$candidate" ] && BRIDGE_SCRIPT="$candidate" && break
done
if [ -n "$BRIDGE_SCRIPT" ]; then
  bash "$BRIDGE_SCRIPT" > /var/log/configure-bridge.log 2>&1 || { echo "bridge configure FAILED, log:"; tail -20 /var/log/configure-bridge.log; exit 1; }
else
  echo "configure-bridge.sh not found on this host, skipping bridge step"
fi
tail -4 /var/log/configure-bridge.log 2>/dev/null || true

echo "== 2. sshd hardening =="
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl reload ssh || systemctl reload sshd || true

echo "== 3. fail2ban + unattended-upgrades =="
DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban unattended-upgrades > /dev/null
systemctl enable --now fail2ban

echo "== 4. ufw: rate-limit ssh, close federation port =="
ufw limit 22/tcp || true
ufw delete allow 8448/tcp 2>/dev/null || true
ufw status numbered | head -20

echo "== 5. rotate livekit key =="
if grep -q "CHANGE-ME-devkey-secret" livekit.yaml; then
  sed -i "s|CHANGE-ME-devkey-secret|$(openssl rand -hex 24)|" livekit.yaml
  docker compose restart livekit
fi

echo "== 6. synapse: registration off =="
sed -i 's/^enable_registration: .*/enable_registration: False/' synapse/homeserver.yaml
grep "^enable_registration" synapse/homeserver.yaml

echo "== 7. caddy security headers =="
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

echo "== 8. final stack state =="
docker compose ps --format '{{.Service}}: {{.Status}}'
echo "== fail2ban sshd jail =="
fail2ban-client status sshd 2>/dev/null || true
