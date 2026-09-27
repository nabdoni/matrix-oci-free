#!/usr/bin/env bash
# Make the appservice tokens deterministic: generate once, write into config.yaml,
# then regenerate the registration FROM that config so both sides always match.
set -euo pipefail
cd /opt/matrix

AS=$(openssl rand -hex 32)
HS=$(openssl rand -hex 32)

python3 - "$AS" "$HS" <<'PY'
import re, sys
as_token, hs_token = sys.argv[1], sys.argv[2]
p = "mautrix-discord/config.yaml"
s = open(p).read()
# normalise: drop any previously injected token/id lines, then insert fresh ones
s = re.sub(r"^\s*(id|as_token|hs_token):.*\n", "", s, flags=re.M)
s = s.replace(
    "appservice:\n",
    "appservice:\n    id: discord\n    as_token: %s\n    hs_token: %s\n" % (as_token, hs_token),
    1,
)
open(p, "w").write(s)
PY

rm -f mautrix-discord/discord-registration.yaml
docker compose run --rm --entrypoint /usr/bin/mautrix-discord mautrix-discord \
  -g -c /data/config.yaml -r /data/discord-registration.yaml

cp mautrix-discord/discord-registration.yaml synapse/discord-registration.yaml
chmod 0644 synapse/discord-registration.yaml

# prove both sides agree before restarting anything
python3 - <<'PY'
import sys
def tok(path, key):
    for line in open(path):
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip().strip('"')
    return None
c, r = "mautrix-discord/config.yaml", "synapse/discord-registration.yaml"
pairs = [("as_token", tok(c, "    as_token") or ""), ]
as_c = tok(c, "    as_token"); as_r = tok(r, "as_token")
hs_c = tok(c, "    hs_token"); hs_r = tok(r, "hs_token")
print("config as_token ==  registration as_token :", bool(as_c) and as_c == as_r)
print("config hs_token ==  registration hs_token :", bool(hs_c) and hs_c == hs_r)
sys.exit(0 if as_c == as_r and hs_c == hs_r and as_c else 1)
PY

docker compose restart synapse
sleep 6
docker compose restart mautrix-discord
sleep 10
docker compose logs --tail 5 mautrix-discord
docker compose ps --format '{{.Service}}: {{.Status}}'
