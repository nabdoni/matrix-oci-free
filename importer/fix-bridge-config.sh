#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix
set -a
. ./.env
set +a
CFG=mautrix-discord/config.yaml

# database URI (example config uses @host, not @hostname)
sed -i "s|uri: postgres://user:password@host/database?sslmode=disable|uri: postgres://synapse:$POSTGRES_PASSWORD@postgres:5432/discord?sslmode=disable|" "$CFG"

# bridge permissions: grant the whole server full access, admin admin
sed -i "s|^\( *\)\"example.com\": user|\1\"$MATRIX_DOMAIN\": full|" "$CFG"
sed -i "s|^\( *\)\"@admin:example.com\": admin|\1\"@admin:$MATRIX_DOMAIN\": admin|" "$CFG"

docker compose up -d mautrix-discord
sleep 6
docker compose logs --tail 4 mautrix-discord
docker compose ps --format '{{.Service}}: {{.Status}}'
