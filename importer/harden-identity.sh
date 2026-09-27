#!/usr/bin/env bash
# harden-identity.sh — identity hardening for an invite-only private server.
#
# Synapse's defaults assume a public server. For a closed community you want
# stronger passwords, no public room directory, and no anonymous room discovery.
# This appends a marked, idempotent block to homeserver.yaml, validates the YAML
# with the YAML parser inside the synapse image, and only then restarts Synapse.
# If validation fails the original file is restored and nothing is restarted.
#
#   usage: sudo bash harden-identity.sh          # apply (idempotent)
#          sudo bash harden-identity.sh show     # print current effective values
#          sudo bash harden-identity.sh rollback # restore the pre-change backup
set -euo pipefail

cd /opt/matrix
HS=synapse/homeserver.yaml
BAK=synapse/homeserver.yaml.pre-identity
START="# buncha-identity:start"
END="# buncha-identity:end"

usage() { sed -n '2,12p' "$0"; exit 1; }
case "${1:-apply}" in
  apply|show|rollback) ;;
  *) usage ;;
esac
MODE="${1:-apply}"

strip_block() {
  python3 - "$HS" "$START" "$END" <<'PY'
import sys
path, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path).read().split("\n")
except FileNotFoundError:
    sys.exit(0)
out, inside = [], False
for line in lines:
    if line.strip() == start:
        inside = True
        continue
    if inside:
        if line.strip() == end:
            inside = False
        continue
    out.append(line)
open(path, "w").write("\n".join(out))
PY
}

case "$MODE" in
  show)
    sudo docker compose exec -T synapse python -c "
import yaml
c = yaml.safe_load(open('/data/homeserver.yaml'))
for k in ('enable_registration','enable_registration_captcha','allow_guest_access',
          'allow_public_rooms_without_auth','allow_public_rooms_over_federation',
          'room_list_publication_rules','password_config','rc_login'):
    print(f'{k}: {c.get(k, \"<default>\")}')
"
    exit 0
    ;;
  rollback)
    [ -f "$BAK" ] || { echo "no backup at $BAK" >&2; exit 1; }
    cp -a "$BAK" "$HS"
    docker compose restart synapse
    echo "rolled back to $BAK"
    exit 0
    ;;
esac

# Never store passwords or the shared secret in a world-readable place.
chmod 600 "$HS" 2>/dev/null || true
[ -f "$BAK" ] || cp -a "$HS" "$BAK"

strip_block

cat >> "$HS" <<'EOF'

# buncha-identity:start
# invite-only, private community. Applied by importer/harden-identity.sh.
# Registration stays off; accounts exist only via importer/invite-user.sh.
# Spelled out explicitly rather than relying on Synapse's default being false.
enable_registration: false
enable_registration_captcha: false
allow_guest_access: false

# Keys verified against Synapse's config reference (password_config.policy).
# `policy.enabled` defaults to false, so without it nothing is enforced. Element
# reads the policy from the server, so there is no separate client-side setting.
password_config:
  enabled: true
  policy:
    enabled: true
    minimum_length: 12
    require_digit: true
    require_symbol: true
    require_lowercase: true
    require_uppercase: true

# No room directory, no discovery: nobody can enumerate your community.
allow_public_rooms_without_auth: false
allow_public_rooms_over_federation: false
room_list_publication_rules:
  - user_id: "*"
    alias: "*"
    room_id: "*"
    action: deny

# Keep login brute-force expensive (Synapse defaults are kept for the rest).
# These are top-level Synapse keys. (A `rate_limiting:` wrapper does not exist and
# Synapse silently ignores unknown keys, so it must not be used.)
rc_registration:
  per_second: 0.003
  burst_count: 3
rc_login:
  address:
    per_second: 0.05
    burst_count: 10
  account:
    per_second: 0.05
    burst_count: 10
  failed_attempts:
    per_second: 0.02
    burst_count: 5
# buncha-identity:end
EOF

# Validate with the parser that will actually read the file.
if ! docker compose exec -T synapse python -c "
import yaml, sys
try:
    yaml.safe_load(open('/data/homeserver.yaml'))
except Exception as e:
    print('YAML ERROR:', e); sys.exit(1)
print('yaml ok')
" 2>/dev/null | grep -q 'yaml ok'; then
  echo "YAML validation failed; restoring $BAK and leaving Synapse alone" >&2
  cp -a "$BAK" "$HS"
  exit 1
fi

docker compose restart synapse
sleep 8
docker compose ps --format '{{.Service}}: {{.Status}}'
docker compose logs --tail 5 synapse
echo
echo "effective values:"
docker compose exec -T synapse python -c "
import yaml
c = yaml.safe_load(open('/data/homeserver.yaml'))
for k in ('enable_registration','allow_public_rooms_without_auth','password_config','room_list_publication_rules'):
    print(f'  {k}: {c.get(k, \"<default>\")}')
"
