#!/usr/bin/env bash
# backup.sh — nightly backup of the buncha stack into OCI Object Storage.
#
#   * PostgreSQL (Synapse + bridge DBs) as a compressed custom-format dump
#   * all configuration: compose file, .env, Caddyfile, livekit.yaml,
#     synapse/homeserver.yaml, mautrix-discord/config.yaml + registration
#
# Uploads to the "buncha-backups" bucket using an OCI CLI instance principal, so
# there is no API key on the box: the instance is matched by the buncha-backup
# dynamic group, which is allowed object storage and nothing else.
#
# 20 GB of Object Storage is Always Free (combined tiers), which is plenty for
# config + DB dumps. Sync media is NOT backed up here - it is managed by Synapse
# media_retention (see README section 5).
set -euo pipefail

BUCKET=buncha-backups
# Tenancy/compartment OCID: from the environment, else COMPARTMENT_ID= in /opt/matrix/.env.
COMPARTMENT_ID=${COMPARTMENT_ID:-$(grep -E '^COMPARTMENT_ID=' /opt/matrix/.env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)}
[ -n "$COMPARTMENT_ID" ] || { echo "set COMPARTMENT_ID (env or /opt/matrix/.env)" >&2; exit 1; }
PREFIX=buncha
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
WORK=/var/backups/buncha
KEEP_DAYS=7
LOG=/var/log/buncha-backup.log
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=1
# auth is a global option; --compartment-id is service-level and not needed for
# object put/list/delete, so it is not passed here.
OCI=(oci --auth instance_principal)

mkdir -p "$WORK"
cd /opt/matrix

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

log "backup starting (stamp $STAMP)"

# 1. databases
docker compose exec -T postgres pg_dumpall -U synapse --clean --if-exists \
  | gzip -9 > "$WORK/db-$STAMP.sql.gz"

# 2. configuration
tar -czf "$WORK/config-$STAMP.tar.gz" \
  --ignore-failed-read \
  docker-compose.yml .env Caddyfile livekit.yaml \
  synapse/homeserver.yaml synapse/discord-registration.yaml \
  mautrix-discord/config.yaml mautrix-discord/discord-registration.yaml

# 3. checksums
( cd "$WORK" && sha256sum db-$STAMP.sql.gz config-$STAMP.tar.gz > "manifest-$STAMP.txt" )

# 4. upload
for f in "$WORK"/db-$STAMP.sql.gz "$WORK"/config-$STAMP.tar.gz "$WORK"/manifest-$STAMP.txt; do
  "${OCI[@]}" os object put --bucket-name "$BUCKET" \
    --name "$PREFIX/$(basename "$f")" --file "$f" --force
  log "uploaded $PREFIX/$(basename "$f") ($(du -h "$f" | cut -f1))"
done

# 5. prune local copies, then prune remote objects older than $KEEP_DAYS
find "$WORK" -type f -mtime +"$KEEP_DAYS" -delete
CUTOFF=$(date -u -d "$KEEP_DAYS days ago" '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -v-"$KEEP_DAYS"d '+%Y-%m-%dT00:00:00Z')
if "${OCI[@]}" os object list --bucket-name "$BUCKET" --prefix "$PREFIX/" --fields name,time-created \
     --query "data[?\"time-created\" < \`'$CUTOFF'\`].name" --raw-output 2>/dev/null | grep . > /tmp/.old-objs; then
  while read -r old; do
    "${OCI[@]}" os object delete --bucket-name "$BUCKET" --name "$old" --force >/dev/null 2>&1 || true
    log "pruned old object $old"
  done < /tmp/.old-objs
  rm -f /tmp/.old-objs
fi

# 6. report bucket usage against the 20 GB free allowance
USED=$("${OCI[@]}" os object list --bucket-name "$BUCKET" --fields name --query 'length(data)' --raw-output 2>/dev/null || echo "?")
log "objects in bucket: $USED (Always Free allowance: 20 GB / 50k requests per month)"
log "backup finished"
