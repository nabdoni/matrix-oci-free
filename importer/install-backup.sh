#!/usr/bin/env bash
# Installs the nightly backup: OCI CLI (instance principal, no keys on the box),
# backup.sh, and the cron entry. Auth only starts working once the
# buncha-backup-policy exists in the tenancy — see README section 5.
set -euo pipefail

echo "== oci cli =="
if ! command -v oci > /dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -q python3-venv
  # venv: installing oci system-wide collides with Debian's urllib3 (PEP 668)
  # NB: the PyPI package "oci" is only the SDK; the CLI is "oci-cli".
  python3 -m venv /opt/oci-cli
  /opt/oci-cli/bin/pip install --quiet --upgrade pip
  /opt/oci-cli/bin/pip install --quiet oci-cli
  ln -sf /opt/oci-cli/bin/oci /usr/local/bin/oci
fi
mkdir -p /root/.oci
cat > /root/.oci/config <<'EOF'
[DEFAULT]
auth=instance_principal
region=us-ashburn-1
output=json
EOF
oci --version

echo "== backup script =="
install -m 0750 /tmp/importer/backup.sh /usr/local/bin/buncha-backup
ln -sf /usr/local/bin/buncha-backup /usr/local/sbin/buncha-backup

echo "== cron (03:17 UTC daily) =="
cat > /etc/cron.d/buncha-backup <<'EOF'
# Nightly buncha backup -> OCI Object Storage bucket buncha-backups
# 03:17 UTC keeps it off the :00/:15 marks everyone else uses.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root /usr/local/bin/buncha-backup >> /var/log/buncha-backup.log 2>&1
EOF
chmod 0644 /etc/cron.d/buncha-backup
systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true

echo "== first run =="
/usr/local/bin/buncha-backup || echo "(first run may fail on auth until buncha-backup-policy exists)"

echo "== local artefacts =="
ls -lh /var/backups/buncha 2>/dev/null | tail -5
echo "== cron =="
cat /etc/cron.d/buncha-backup
