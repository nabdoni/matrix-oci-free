#!/usr/bin/env bash
# Pilot configuration for the Discord -> Matrix sync.
#
# mautrix-discord backfill structure (verified from the generated example config):
#   backfill:
#     forward_limits:
#       initial: {dm, channel, thread}   # history pulled when a portal is first created
#       missed:  {dm, channel, thread}   # catch-up on bridge start (-1 = everything since last msg)
#     max_guild_members: -1
#
# Pilot = small initial limit so the first channel is easy to verify, and missed=-1
# so anything that happens while the bridge is down is pulled on the next start.
set -euo pipefail
cd /opt/matrix

python3 - <<'PY'
import re
p = "mautrix-discord/config.yaml"
lines = open(p).read().split("\n")

INITIAL = 500     # messages of history for the pilot channel
MISSED = -1       # catch-up: everything since the last bridged message

in_backfill = in_forward = in_initial = in_missed = False
out = []
for line in lines:
    stripped = line.strip()
    indent = len(line) - len(line.lstrip())
    if indent == 4 and stripped == "backfill:":
        in_backfill, in_forward, in_initial, in_missed = True, False, False, False
    elif in_backfill and indent == 8 and stripped == "forward_limits:":
        in_forward, in_initial, in_missed = True, False, False
    elif in_forward and indent == 12 and stripped.startswith("initial:"):
        in_initial, in_missed = True, False
    elif in_forward and indent == 12 and stripped.startswith("missed:"):
        in_initial, in_missed = False, True
    elif in_forward and indent <= 8:
        in_forward = in_initial = in_missed = False

    if (in_initial or in_missed) and stripped.startswith("channel:"):
        line = " " * indent + "channel: %d" % (INITIAL if in_initial else MISSED)
    out.append(line)

open(p, "w").write("\n".join(out))
print("patched backfill limits")
PY

docker compose restart mautrix-discord
sleep 6
docker compose logs --tail 2 mautrix-discord
echo "--- effective backfill limits ---"
awk '/backfill:/{f=1} f{print; n++} n>26{exit}' mautrix-discord/config.yaml | grep -vE '^\s*#'
docker compose ps --format '{{.Service}}: {{.Status}}'
