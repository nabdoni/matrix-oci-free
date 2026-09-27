#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix
set -a
. ./.env
set +a

if ! grep -q "mautrix-discord:" docker-compose.yml; then
cat >> docker-compose.yml <<'YAML'

  mautrix-discord:
    image: mautrix/discord:latest
    restart: unless-stopped
    volumes:
      - ./mautrix-discord:/data
YAML
fi

if [ ! -f mautrix-discord/config.yaml ]; then
  mkdir -p mautrix-discord
  docker compose run --rm mautrix-discord || true
fi

sed -i "s|address: https://matrix.example.com|address: http://synapse:8008|" mautrix-discord/config.yaml
sed -i "s|domain: example.com|domain: $MATRIX_DOMAIN|" mautrix-discord/config.yaml
sed -i "s|address: http://localhost:29334|address: http://mautrix-discord:29334|" mautrix-discord/config.yaml
sed -i "s|uri: postgres://user:password@hostname/database?sslmode=disable|uri: postgres://synapse:$POSTGRES_PASSWORD@postgres:5432/discord?sslmode=disable|" mautrix-discord/config.yaml
sed -i "s|\"example.com\": \"full\"|\"$MATRIX_DOMAIN\": \"full\"|" mautrix-discord/config.yaml
sed -i "s|\"@admin:example.com\": \"admin\"|\"@admin:$MATRIX_DOMAIN\": \"admin\"|" mautrix-discord/config.yaml

docker compose exec -T postgres psql -U synapse -d synapse -c "CREATE DATABASE discord;" || true

if [ ! -f mautrix-discord/discord-registration.yaml ]; then
  docker compose run --rm --entrypoint /usr/bin/mautrix-discord mautrix-discord -g -c /data/config.yaml -r /data/discord-registration.yaml
fi
cp mautrix-discord/discord-registration.yaml synapse/discord-registration.yaml
chmod 0644 synapse/discord-registration.yaml

if ! grep -q "app_service_config_files" synapse/homeserver.yaml; then
  printf '\n# mautrix-discord appservice\napp_service_config_files:\n  - /data/discord-registration.yaml\n' >> synapse/homeserver.yaml
fi

if ! head -1 docker-compose.yml | grep -q "^name:"; then
  sed -i "1i name: buncha" docker-compose.yml
  docker compose -p matrix down --remove-orphans || true
fi

docker compose up -d
docker compose restart synapse
sleep 8
docker compose ps --format '{{.Service}}: {{.Status}}'
echo ===
docker compose logs --tail 6 mautrix-discord
