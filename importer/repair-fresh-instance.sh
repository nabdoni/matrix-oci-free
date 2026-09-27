#!/usr/bin/env bash
# One-shot repair for a freshly (re)created instance: this host's IPv6 is broken, so
# apt and Docker registry pulls fail unless we force IPv4 and disable IPv6 first.
set -euo pipefail

echo 'Acquire::ForceIPv4 true;' > /etc/apt/apt.conf.d/99force-ipv4
cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
sysctl --system > /dev/null

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 ufw

systemctl enable --now docker
systemctl restart docker
usermod -aG docker ubuntu

echo "waiting for cloud-init to finish writing /opt/matrix ..."
for _ in $(seq 1 60); do
  [ -f /opt/matrix/bootstrap.sh ] && break
  sleep 5
done

bash /opt/matrix/bootstrap.sh
echo "== stack =="
docker compose -f /opt/matrix/docker-compose.yml ps --format '{{.Service}}: {{.Status}}' || true
