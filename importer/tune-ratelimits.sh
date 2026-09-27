#!/usr/bin/env bash
# tune-ratelimits.sh — raise Synapse's per-room send limit so a multi-year
# backfill is not throttled to Synapse's default rc_message (burst 10, 0.1/s
# => ~6 messages/minute, which would take years for a real archive).
#
#   usage: tune-ratelimits.sh import   # raise limits (bulk import mode)
#          tune-ratelimits.sh default  # restore conservative limits
#
# Import mode raises only rc_message. Login/registration limits are deliberately
# left alone so the server is not more brute-forceable while importing.
# The block is fenced by start/end markers so `default` removes it cleanly.
# (rc_message is a top-level Synapse key; there is no `rate_limiting:` wrapper.)
set -euo pipefail
cd /opt/matrix
HS=synapse/homeserver.yaml
START="# buncha-bulk-import:start"
END="# buncha-bulk-import:end"

mode="${1:-import}"
case "$mode" in import|default) ;; *) sed -n '2,10p' "$0"; exit 1 ;; esac

remove_block() {
  python3 - "$HS" "$START" "$END" <<'PY'
import sys
path, start, end = sys.argv[1:4]
out, inside = [], False
for line in open(path).read().split("\n"):
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

# Also strip the block the previous version of this script wrote (it used a
# non-existent `rate_limiting:` key and had no end marker).
python3 - "$HS" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")
out, i = [], 0
while i < len(lines):
    if lines[i].strip() == "# buncha-bulk-import":
        i += 1
        while i < len(lines) and (lines[i].startswith((" ", "\t", "#")) or lines[i].strip() == "rate_limiting:"):
            i += 1
        continue
    out.append(lines[i])
    i += 1
open(path, "w").write("\n".join(out))
PY

remove_block

if [ "$mode" = "import" ]; then
  cat >> "$HS" <<EOF

$START
# Raised only for the duration of a history import; revert with:
#   sudo bash tune-ratelimits.sh default
rc_message:
  per_second: 100
  burst_count: 10000
$END
EOF
  echo "raised rc_message for import"
else
  echo "restored Synapse default rate limits"
fi

docker compose restart synapse
sleep 8
docker compose ps --format '{{.Service}}: {{.Status}}'
docker compose logs --tail 3 synapse
