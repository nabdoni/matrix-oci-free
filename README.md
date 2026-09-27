# buncha

Self-hosted, open-source Discord alternative running on Oracle Cloud Always Free (Ampere A1).

`buncha` = **b**ecause **u** ... **n**o **c**loud **h**osted **a**lternatives — a Matrix stack plus a Discord
bridge, deployed with Terraform on a single ARM VM.

```
Discord ──(mautrix-discord appservice)──> Synapse ──> Element Web
                                              ├── PostgreSQL (state)
                                              └── LiveKit (voice/video) ──> Caddy (TLS)
```

| Component | Image | Purpose |
|---|---|---|
| `synapse` | `ghcr.io/element-hq/synapse:latest` | Matrix homeserver |
| `postgres` | `postgres:16-alpine` | Synapse DB + bridge DB |
| `livekit` | `livekit/livekit-server` | SFU for voice/video |
| `element` | `ghcr.io/element-hq/element-web:latest` | Web client |
| `caddy` | `caddy:2-alpine` | TLS + reverse proxy |
| `mautrix-discord` | `dock.mau.dev/mautrix/discord:latest` | Discord portal bridge (appservice) |

---

## 1. Current state

Live VM: `<SERVER_IP>` (`ubuntu@`, key auth only), `us-ashburn-1`, compartment = root tenancy.

* All five original services are up (`caddy`, `element`, `livekit`, `postgres` healthy, `synapse`).
* `mautrix-discord` is deployed and registered as a Synapse appservice; it still needs a **Discord user
  token login** before it syncs anything (see §6).
* Domains are placeholders (`matrix.example.com`, `livekit.example.com`, `chat.example.com`) — no DNS yet,
  so Caddy cannot issue real certificates and nothing is reachable from the public internet.
* No admin user has been created yet (§6).

### Site-specific values (not in this repo)

Deployment-specific values (server IP, OCIDs, admin allowlist, contact email) are kept out of this public
repo. `<SERVER_IP>` and similar placeholders stand in for them. Where each one is read from:

| Value | Read from |
|---|---|
| tenancy/user OCIDs, `admin_cidr`, `objectstorage_namespace`, `admin_email` | `terraform/terraform.tfvars` (git-ignored; see `terraform.tfvars.example`) |
| `COMPARTMENT_ID` (backup target) | env var or `COMPARTMENT_ID=` in `/opt/matrix/.env` on the VM |
| `ADMIN_CIDR` (admin path allowlist) | 2nd argument to `harden-web-edge.sh` or `ADMIN_CIDR=` in `/opt/matrix/.env` |

### Repo layout

```
matrix-oci-free/            # this repo
├── terraform/              # OCI infrastructure (Terraform)
│   ├── main.tf             # VCN, subnet, IGW, route table, security list
│   ├── compute.tf          # A1 instance + cloud-init
│   ├── variables.tf        # sizing (2 OCPU / 12 GB), region, OCIDs, SSH CIDR
│   ├── cloud-init.yaml     # first-boot: IPv4 fix, Docker, compose stack
│   ├── free-tier-guard.sh  # asserts state stays inside Always Free (Linux/macOS)
│   ├── free-tier-guard.ps1 # same check for Windows
│   └── terraform.tfvars    # untracked, real values
└── importer/
    ├── configure-bridge.sh   # idempotent mautrix-discord deploy + registration
    ├── fix-bridge-config.sh  # bridge DB URI + permissions
    ├── fix-bridge-tokens.sh  # deterministic appservice tokens
    ├── pilot-backfill.sh     # history backfill limits for the pilot
    ├── fix-runtime.sh        # livekit secrets, element config, ufw, caddy headers
    ├── harden.sh             # sshd, fail2ban, unattended upgrades
    ├── repair-fresh-instance.sh  # IPv4/docker repair for a rebuilt VM
    ├── backup.sh             # nightly backup -> OCI Object Storage
    ├── install-backup.sh     # installs OCI CLI + cron
    └── install-bridge.sh     # (see §6)
```

Rebuild recipe for a fresh instance (all idempotent):

```bash
scp -r importer ubuntu@<ip>:/tmp/
ssh ubuntu@<ip>
sudo bash /tmp/importer/repair-fresh-instance.sh   # only if Docker is missing
sudo bash /tmp/importer/fix-runtime.sh
sudo bash /tmp/importer/configure-bridge.sh
sudo bash /tmp/importer/fix-bridge-config.sh
sudo bash /tmp/importer/fix-bridge-tokens.sh
sudo bash /tmp/importer/pilot-backfill.sh
sudo bash /tmp/importer/harden.sh
```

Everything runtime-generated (`homeserver.yaml`, `config.yaml`, `discord-registration.yaml`, `.env`,
Terraform state, keys) is git-ignored on purpose.

---

## 2. Free tier: what the limits actually are

Verified against Oracle's Always Free documentation:

| Resource | Always Free allowance | What this project uses |
|---|---|---|
| A1 compute | **2 OCPU / 12 GB total**, 1,500 OCPU-h + 9,000 GB-h per month | 1 instance, target 2 OCPU / 12 GB |
| Block volume | 200 GB total (boot + volumes) | 50 GB boot |
| Object storage | 20 GB combined tiers, 50,000 API requests/month | backups only |
| Outbound data | 10 TB/month | negligible |
| Load balancer | one 10 Mbps flexible LB | not used (Caddy instead) |
| Public IPv4 | one per VNIC | 1 ephemeral |

> **The VM was originally created at 4 OCPU / 24 GB, which is 2× the Always Free allowance** and would have
> been billed as paid overage. It is now **2 OCPU / 12 GB** — note that changing the A1 shape made Terraform
> *replace* the instance (A1 cannot be resized in place), which is why the IP changed from `<OLD_SERVER_IP>`
> to `<SERVER_IP>`. Re-check `terraform.tfvars` and DNS after any such change.

**Enforcement, in three layers:**

1. `variables.tf` has hard `validation` blocks — `ocpus <= 2`, `memory_in_gbs <= 12`. Terraform refuses to
   plan anything larger.
2. `free-tier-guard.sh` / `free-tier-guard.ps1` read the *live* state and fail if the tenancy has more than
   2 OCPU / 12 GB / 200 GB of block volume, if an instance is not in the home region, or if always-billed
   extras (NAT gateway, WAF, reserved IPs, extra LBs) appear. Run it before and after every apply:
   `.\free-tier-guard.ps1 -Plan` on Windows, `./free-tier-guard.sh` elsewhere.
3. **One manual step left:** create an OCI Budget with a 1 USD/month alert (free; hard spending limits are a
   paid-account feature, so this alert is the only runtime tripwire). Console → Governance → Budgets.

**Idle reclamation risk:** Oracle reclaims idle Always Free instances when, over a 7-day window, the 95th
percentile of CPU, network and (for A1) memory utilisation are all below 20%. A quiet Matrix server can hit
this. Mitigations: the nightly backup job (§5) does real work, and a busy community server never trips it.
If the server is genuinely idle, add a low-cost keepalive (e.g. a cron that syncs and posts to a private
admin room) rather than leaving it dormant.

---

## 3. Security posture

The goal is a private server: nothing is discoverable, and the only way in is a real client or a real login.

### Already in place

* **SSH** — key-only auth (`PasswordAuthentication no`, `PermitRootLogin no`), restricted to a single source
  IP in the OCI security list (`admin_cidr = <your-ip>/32`), `ufw limit 22/tcp`, and fail2ban watching
  `sshd`. Changing home IP means editing `terraform.tfvars` and re-applying.
* **No federation** — port 8448 closed in both the security list and ufw, so the server cannot be discovered
  or crawled by other homeservers.
* **No public registration** — `enable_registration: False`; users are created deliberately by an admin.
* **Secrets rotated** — LiveKit `devkey`/`secret` replaced `CHANGE-ME`; PostgreSQL password is random
  (32 hex chars) and never leaves the VM except in backups.
* **Least exposure** — PostgreSQL and Synapse are not published to the host; only Caddy (80/443) and
  LiveKit's media ports (3478 TCP/UDP, 7881, 50000-60000 UDP) are reachable. LiveKit must stay reachable
  or calls fail behind NAT; it is the one deliberately public surface.
* **TLS + headers** — Caddy issues certificates and serves HSTS, `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy` and `frame-ancestors 'none'`; the `Server` header is suppressed. Caddy's admin API is
  `admin off`.
* **Patching** — `unattended-upgrades` for security updates, `fail2ban` for brute force.
* **Logs** — `docker compose logs`, `journalctl -u ssh`, fail2ban history, and the Synapse bootstrap log.

### OWASP Top 10 coverage

| Risk | Mitigation here |
|---|---|
| A01 Broken access control | closed registration, admin-only user creation, SSH IP lock, no federation, private rooms |
| A02 Cryptographic failures | TLS everywhere, HSTS, bcrypt password hashes in Synapse, random generated secrets |
| A03 Injection | Synapse uses parameterised SQL; nothing user-supplied reaches a shell; containers isolate services |
| A04 Insecure design | minimal external surface, no public signup, rate limits on login/rc_* |
| A05 Security misconfiguration | hardened image defaults, `admin off`, closed federation port, no default LiveKit keys, `ufw` default-deny |
| A06 Vulnerable components | unattended security updates; `docker compose pull && up -d` for image updates |
| A07 Auth failures | fail2ban, `ufw limit`, no password SSH, rate limiting, appservice tokens for the bridge |
| A08 Integrity failures | images pulled from official registries; pin tags/digests when stabilised |
| A09 Logging gaps | container/system/sshd logs retained; centralising to OCI Logging is a TODO |
| A10 SSRF | Synapse URL preview stays **disabled** (never enable it on a private server) |

### Remaining security TODOs

* Point DNS at the VM and get real certificates; consider a Cloudflare proxy or Caddy `tls internal` if you
  never want the origin IP public.
* Keep `admin_cidr` current; consider a second admin key or OCI Bastion (free) for recovery.
* Add `Content-Security-Policy` for Element once verified not to break the client.
* Optional: WAF in front of Caddy, and alerting on fail2ban bans.

---

## 4. Runbook

```bash
# connect
ssh ubuntu@<OLD_SERVER_IP>
cd /opt/matrix

# stack control (compose project name: buncha)
sudo docker compose ps
sudo docker compose logs -f --tail 100 synapse
sudo docker compose restart synapse
sudo docker compose up -d            # picks up changed config files
sudo docker compose pull && sudo docker compose up -d   # image updates

# re-run first-boot bootstrap (idempotent, generates secrets if missing)
sudo bash /opt/matrix/bootstrap.sh

# change domains later
sudo nano /opt/matrix/.env && sudo bash /opt/matrix/apply-env.sh

# re-apply hardening / bridge after a rebuild
sudo bash /tmp/configure-bridge.sh    # or repo: importer/configure-bridge.sh
sudo bash /tmp/harden.sh              # or repo: importer/harden.sh

# disk / database
df -h
sudo docker compose exec postgres psql -U synapse -d synapse -c '\l'
```

Terraform:

```bash
cd terraform
terraform init
terraform plan
terraform apply
./free-tier-guard.sh            # must pass before/after every apply
```

---

## 5. Storage: is 50 GB enough, and the free bucket

Synapse media is the growth driver: every image/attachment in every room lands on the boot volume, and Discord
history imports are attachment-heavy. 50 GB is fine for text and the pilot, and it will be tight for a full
archive with media. Four levers, cheapest first:

1. **Retention on the server** — cap media age so old files are deleted automatically. **Not enabled yet**
   on purpose: do not turn on deletion during a first import (§6.3). Apply after verification:
   ```yaml
   # /opt/matrix/synapse/homeserver.yaml
   media_retention:
     local_max_age: 30d
     remote_max_age: 30d
   max_upload_size: 20M
   ```
2. **Free bucket — already created: `buncha-backups` (20 GB Always Free, 50k requests/month).**
   `importer/backup.sh` runs nightly at 03:17 UTC via `/etc/cron.d/buncha-backup` and uploads a
   `pg_dumpall` (compressed) plus a config tarball and SHA-256 manifest, keeping 7 days. It authenticates with
   an **instance principal**, so there is no API key on the box: the instance matches the
   `buncha-backup` dynamic group, which is (once the policy below exists) allowed object storage only.
   Install with `sudo bash /tmp/importer/install-backup.sh`; restore with `gunzip -c db-*.sql.gz | psql` and
   untarring the config over `/opt/matrix`.
   > **Remaining manual step:** create the policy that authorises the dynamic group. The OCI CLI on Windows
   > kept mangling the JSON, so paste this in Console → Identity → Policies:
   > ```json
   > [
   >   { "effect": "ALLOW", "statement": "Allow dynamicgroup buncha-backup to manage buckets in tenancy" },
   >   { "effect": "ALLOW", "statement": "Allow dynamicgroup buncha-backup to manage objects in tenancy" }
   > ]
   > ```
   > Until then the backup job writes the local dump fine and then fails the upload with an
   > object-storage authorization error — the dumps are valid, only the upload is blocked. Verify with
   > `sudo oci os bucket list --auth instance_principal --compartment-id <tenancy_ocid>`.
3. **Free local headroom** — the 200 GB block allowance is free, so the boot volume can grow to e.g.
   150 GB at no cost (`boot_volume_size_in_gbs` in Terraform). Growth is online; shrinking is not, and note
   that changing the *shape* replaces the instance (see §2).
4. **Text-vs-media split** — for "years of conversation", keep the text in Matrix (cheap, searchable) and
   treat media as disposable via retention. Media is what actually fills a disk; message rows do not.

Nothing needs to "clear memory" on a schedule: RAM is not the constraint (see §2 — 12 GB is ample, and a
2 GB swapfile is in place for backfill spikes). Disk is the constraint, and retention plus the bucket handle it.

---

## 6. Pilot export: one channel, end to end

The bridge is deployed, registered and healthy — it just needs a Discord login. `pilot-backfill.sh` has
already set the limits (`backfill.forward_limits.initial.channel: 500`, `missed.channel: -1`, i.e. catch up
on everything since the last bridged message whenever the bridge restarts).

1. **Pick a test channel** with some history but nothing critical (e.g. `#general-test`).
2. **Log the bridge in** (one-time, on the VM):
   ```bash
   cd /opt/matrix
   sudo docker compose exec mautrix-discord /usr/bin/mautrix-discord login
   # paste a Discord user token when prompted
   ```
   Use a dedicated throwaway Discord account: a user token grants full read/write access to that account's
   DMs and servers. Automating a user token is against Discord's ToS and can get the account banned.
3. **Invite only the pilot channel** from Discord: right-click the channel → *Invite to Matrix* (the bridge
   bot posts a link) → open it in Element. Do **not** invite the whole server yet.
4. **Verify completeness** — the things that commonly go wrong:
   * message count and oldest date in the Matrix room vs Discord;
   * attachments/inline images resolve (media cached, not broken links);
   * threads, replies, edits and deletions;
   * member list, roles and display names;
   * then send a few test messages **both** directions.
5. **Safety net for "no history is lost"** — Discord's API will not hand the bridge everything. For the same
   channel, also run an independent export and keep it: [DiscordChatExporter](https://github.com/Tyrrrz/DiscordChatExporter)
   (`tyrrrz/discordchatexporter`, CLI or Docker) can pull a channel to JSON/HTML **with media**
   (`--media --media-dir`), including threads and edits. Cheap insurance, and the JSON is the input to any
   future importer. Upload the result to the `buncha-backups` bucket.
6. **Widen gradually** — do not "import everything" on the first run, but see §6.2: a multi-year archive
   needs a staged bulk import, not a thousand manual invites.

### 6.2 Bulk import: a multi-year archive across many channels

**The real bottleneck is Synapse's rate limiter, not Discord's.** With the generated `homeserver.yaml`
(Synapse's default `rc_message`: burst 10, 0.1/s) a backfill pushes ~6 messages/minute, i.e. ~3,600/day.
A 500k-message archive would take over a year. `importer/tune-ratelimits.sh` fixes that:

```bash
sudo /usr/local/bin/tune-ratelimits.sh import    # rc_message 100/s, burst 10000
sudo /usr/local/bin/tune-ratelimits.sh default   # revert when the import is done
```

It appends a marked `rate_limiting:` block to `homeserver.yaml` and restarts Synapse (~10 s downtime).
Login/registration limits are left at their defaults, so this does not make the server easier to brute-force.
**Already applied on the current VM** (import mode) — revert it when you're done.

Other things that matter at this scale:

* **One portal per channel, invited from Discord.** The bridge has no bulk-invite CLI (`mautrix-discord
  --help` has only config/registration flags), so each channel is invited via the Discord UI
  (right-click → *Invite to Matrix*) or a bridge command in a DM with the bot. Doing ~50 channels is fine;
  doing ~500 is painful, so count your channels first and prefer the exporter path for the long tail.
* **Order of operations per channel:** invite → bridge fetches history → it lands in the Matrix room.
  Backfill is restart-safe: `missed.channel: -1` means "everything since the last bridged message", so
  killing and restarting the bridge never loses or duplicates your place in a channel.
* **Raise `initial.channel` for real archives.** The config's default (500) is a *pilot* number; the
  generated comment notes a special "unlimited" value is not supported, so set an explicit high limit
  (e.g. `100000`) once a channel is verified. Note the bridge fetches a channel's whole history into memory
  before replaying it, so very large channels spike RAM — the 2 GB swapfile and 12 GB total are why.
* **Expect this to take hours-to-days, not minutes.** Discord's history endpoint is 50 req/min per channel
  (100 messages per request); Synapse has to persist and federate-free-index every message. Watch progress
  with `docker compose logs -f mautrix-discord` and `docker compose exec synapse psql -U matrix -c
  "select count(*) from events;"`.
* **Don't delete or archive the Discord server until §6.3 verification passes.** The bridge only sees what
  the API still serves.

### 6.3 Media: the part that will actually fill the disk

Text is cheap (~2-3 KB per Matrix message in Postgres, so a 1M-message archive is 2-3 GB). Media is
whatever your history happens to contain, and it is usually 100× the text. Three decisions, in order:

1. **Measure before you buy anything.** `importer/measure-media.ps1` (run on your PC, not the VM — the
   DiscordChatExporter Docker image is amd64-only) exports one busy channel with media and extrapolates.
   Do this on the *busiest* channel for a pessimistic number.
2. **Get the media out of the VM early, for the same reason as the text.** Old Discord attachment URLs
   are not guaranteed to keep resolving — Discord's CDN has retired links for long-uploaded files, and a
   404 during a months-long backfill is permanent loss. Pull attachments with
   `dce export --media` (or `!media download` in Element) as you go, don't rely on the bridge to fetch
   them years later.
3. **Decide where media lives:**

   | Option | Cost | Use when |
   | --- | --- | --- |
   | Boot volume 50 → 150-200 GB | **Free** (200 GB block allowance) | You want media *in* Matrix and can live with retention |
   | `buncha-backups` bucket | Free, 20 GB | DB/config backups only — too small for a media archive |
   | Backblaze B2 | 3 GB free, then ~$6/TB, free egress ≤3× stored | Cheapest "archive everything" option, wants an S3-compatible target |
   | Cloudflare R2 | 10 GB free, **zero egress fees** | Same, if you'd otherwise serve media through OCI |

   **Recommended shape for a years-long archive:** all text in Matrix (cheap, searchable, the living
   copy), media pulled in parallel into cheap object storage with the DiscordChatExporter JSON as the
   manifest. Then optionally grow the boot volume to the full free 200 GB and let the bridge keep a
   recent-media copy in Matrix with `media_retention` pruning the rest.

Retention is deliberately **not** enabled yet — auto-deleting your media during the import would be the
worst possible failure mode. `media_retention` + `max_upload_size` (§5) get set *after* verification, and
`importer/disk-guard.sh` (cron, every 10 min) pauses the bridge at 85% disk so Postgres can't die while
media lands. It never deletes anything.

## 7. Gotchas already hit (saves the next person a day)

* **OCI fingerprint** — Always Free accounts now show a *console* fingerprint that does **not** match the
  OpenSSL MD5 of the key. Use the exact string from the OCI console with an Oracle-generated key
  (`openssl genrsa` keys are rejected). Wrong value → `401 NotAuthenticated`.
* **IPv6 is broken on this host** — apt and Docker registry pulls failed with
  `dial tcp [2600:...]:443: network is unreachable`. Fix: `Acquire::ForceIPv4 true` in
  `/etc/apt/apt.conf.d/99force-ipv4`, `net.ipv6.conf.*.disable_ipv6=1` in
  `/etc/sysctl.d/99-disable-ipv6.conf`, then restart Docker. Mirrored in `cloud-init.yaml` via `runcmd`.
* **Image moves** — `matrixserver/synapse` and `vectorim/element-web` no longer exist (404). Use
  `ghcr.io/element-hq/synapse` and `ghcr.io/element-hq/element-web`. mautrix images are **only** on
  `dock.mau.dev` (both Docker Hub and ghcr.io return denied) and are multi-arch (`:latest` is a manifest
  with amd64+arm64, and points at the newest commit, not the newest release).
* **mautrix registration** — the image's entrypoint is a bootstrap script, so
  `docker compose run mautrix-discord -g ...` fails with `exec: "-g": executable file not found`. Bypass it:
  `docker compose run --rm --entrypoint /usr/bin/mautrix-discord mautrix-discord -g -c /data/config.yaml -r /data/discord-registration.yaml`.
* **The bridge image chowns `/data` to UID 1337** — expected, not a bug.
* **cloud-init drift** — manual fixes on the VM are not in the Terraform source; re-apply
  `configure-bridge.sh` / `harden.sh` after any rebuild, and keep `cloud-init.yaml` in sync.
* **Appservice tokens** — `mautrix-discord -g` writes a registration with fresh random tokens but does *not*
  write them back into `config.yaml`, so the bridge authenticates with a blank token and Synapse answers
  `401 M_UNKNOWN_TOKEN`. `fix-bridge-tokens.sh` generates the tokens, injects them into `config.yaml`, then
  regenerates the registration from that config so both sides match.
* **Registration permissions** — the generated file is `0600` owned by the bridge's UID 1337; Synapse runs as
  a different UID and dies with `PermissionError: /data/discord-registration.yaml`. `chmod 0644` it.
* **LiveKit config keys** — `udp_range: 50000-60000` is not valid; current LiveKit wants
  `port_range_start` / `port_range_end`. With a bad key the server exits 0 immediately and Docker reports
  `Restarting (0)`, which looks like a crash loop but is really a config parse failure.
* **OCI CLI on the VM** — the PyPI package `oci` is only the SDK (no `oci` command); the CLI is `oci-cli`,
  and it must live in a venv (Ubuntu 24.04 is PEP 668 managed and Debian's urllib3 blocks a system install).
  The upstream `install.sh` URL now 404s.
* **Windows + OCI CLI** — PowerShell mangles JSON args and `file://` inputs for `oci iam policy create`; that
  policy is listed in §5 for manual creation. Also note `terraform` is not on PATH in a fresh PowerShell
  (winget puts it in `%LOCALAPPDATA%\Microsoft\WinGet\Links`); the guard script resolves it itself.
* **A1 shape changes replace the instance** — Terraform cannot resize A1 in place, so changing
  `ocpus`/`memory_in_gbs` destroys and recreates the VM, losing `/opt/matrix` and changing the public IP.
* **Synapse rate limits make bulk backfill impossible out of the box** — the generated `homeserver.yaml`
  has no `rate_limiting:` section at all, so `rc_message` defaults to burst 10 / 0.1 per second (~6 msgs/min).
  Multi-year imports need `tune-ratelimits.sh import`, and you must remember to run it back to `default`.
* **`--compartment-id` is not an OCI CLI global option** — `oci --auth instance_principal
  --compartment-id X os object put` dies with `No such command '--compartment-id'`; auth is global,
  compartment is service-level, and object put/list/delete don't need it.
* **A full disk takes Postgres down with it** — hence `disk-guard.sh`: pause the bridge at 85%, resume at
  75%, delete nothing, and treat 95% as an emergency.

---

## 8. TODO / next steps

- [ ] **Create the `buncha-backup-policy`** (JSON in §5) so the nightly backup can upload
- [ ] **OCI Budget alert** at 1 USD/month (free) as the cost tripwire
- [ ] Create the Synapse admin account and first real users
- [ ] Point DNS at `<SERVER_IP>`, set real domains in `/opt/matrix/.env`, run `apply-env.sh`
- [ ] Log the bridge in with a Discord token and run the single-channel pilot (§6)
- [ ] `importer/measure-media.ps1` on the busiest channel → decide the media plan (§6.3)
- [ ] Raise `initial.channel` to a real-archive limit, then bulk-import the remaining channels (§6.2)
- [ ] Pull media in parallel with `dce export --media` into B2/R2; keep the JSON as the manifest (§6.3)
- [ ] Cross-check the pilot against a DiscordChatExporter JSON export of the same channel
- [ ] After verification: set `media_retention` + `max_upload_size`, grow boot volume if keeping media in Matrix
- [ ] `sudo /usr/local/bin/tune-ratelimits.sh default` once the import is finished
- [ ] Add an OCI budget/bucket usage dashboard check so the 20 GB bucket never silently fills
- [ ] Import remaining Discord channels; document the final Matrix room-per-channel layout
- [ ] Pin image digests; schedule `docker compose pull` updates
- [ ] Add monitoring (uptime check on Element, disk-usage alert) and export logs to OCI Logging
- [ ] Add the Element `livekit` config key check (voice in the web client) once a real domain is live

## 9. Credentials

Kept **off** the repo and out of git: `~/.oci/config`, `~/.oci/oracle.pem`, `~/.ssh/id_ed25519`,
`terraform/terraform.tfvars`, `/opt/matrix/.env`, `/opt/matrix/synapse/homeserver.yaml`.
Rotate by regenerating the relevant item and re-running the matching script.
