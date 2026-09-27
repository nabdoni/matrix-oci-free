#!/usr/bin/env bash
# disk-guard.sh — keeps a multi-year media import from filling the boot volume.
#
# Postgres and Synapse die badly on a full disk, so this runs every 10 minutes:
#   * logs usage
#   * at >= 85%: pauses the bridge (history import stops; Synapse/Postgres stay up)
#   * at <= 75% again: resumes the bridge
#   * at >= 95%: also stops Synapse writes by taking Caddy down? No — it only
#     alerts loudly, because silently deleting your history is worse than a full disk.
#
# It never deletes anything. Retention decisions are yours (see README section 5).
set -euo pipefail

THRESHOLD_PAUSE=85
THRESHOLD_RESUME=75
LOG=/var/log/buncha-disk-guard.log
PAUSED_MARKER=/var/backups/buncha/.bridge-paused

mkdir -p "$(dirname "$PAUSED_MARKER")"
log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }

USE=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
GB_FREE=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')
log "root volume ${USE}% used, ${GB_FREE}G free (pause at ${THRESHOLD_PAUSE}%, resume at ${THRESHOLD_RESUME}%)"

cd /opt/matrix

if [ -f "$PAUSED_MARKER" ]; then
  if [ "$USE" -le "$THRESHOLD_RESUME" ]; then
    docker compose start mautrix-discord
    rm -f "$PAUSED_MARKER"
    log "usage back to ${USE}%: resumed mautrix-discord"
  else
    log "bridge still paused (${USE}%)"
  fi
elif [ "$USE" -ge "$THRESHOLD_PAUSE" ]; then
  docker compose stop mautrix-discord
  : > "$PAUSED_MARKER"
  log "usage hit ${USE}%: PAUSED mautrix-discord to protect Synapse/Postgres"
  log "ACTION: free space (grow boot volume, prune media, or archive to Object Storage) then it auto-resumes at <=${THRESHOLD_RESUME}%"
  if [ "$USE" -ge 95 ]; then
    log "CRITICAL: volume >= 95% full. Postgres may already be erroring. Check: docker compose logs postgres | tail -50"
  fi
fi
