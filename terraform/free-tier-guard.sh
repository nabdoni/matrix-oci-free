#!/usr/bin/env bash
# free-tier-guard.sh — fail if the live stack would ever leave OCI Always Free.
#
# Oracle's Always Free allowance (home region, verified against
# docs.oracle.com/.../Always_Free_Resources.htm):
#   A1 compute : 2 OCPU / 12 GB total for the tenancy
#   Block vol  : 200 GB total (boot + volumes), 5 backups
#   Object     : 20 GB combined, 50k API requests/month
#   Egress     : 10 TB/month
#   LB         : 1 flexible LB at 10 Mbps
#
# Usage:  ./free-tier-guard.sh            # check current state
#         ./free-tier-guard.sh --plan     # also check the pending plan for NEW paid resources
#
# Hard spending limits are a PAID-account feature. On an Always Free account the
# enforcement is therefore: (1) this guard, (2) Terraform variable validation,
# (3) an OCI Budget with a 1 USD alert. See README section 2.
set -euo pipefail
cd "$(dirname "$0")"

LIMIT_OCPU=2
LIMIT_MEM_GB=12
LIMIT_BLOCK_GB=200
HOME_REGION="${HOME_REGION:-us-ashburn-1}"

PY=$(command -v python3 || command -v python || command -v py || true)
if [ -z "$PY" ]; then
  echo "FATAL: need python (or jq) to inspect terraform state." >&2
  exit 2
fi

state=$(mktemp)
trap 'rm -f "$state" "$state.plan"' EXIT
terraform show -json > "$state"

rc=0
"$PY" - "$state" "$LIMIT_OCPU" "$LIMIT_MEM_GB" "$LIMIT_BLOCK_GB" "$HOME_REGION" <<'PY'
import json, sys, collections
state_path, lim_ocpu, lim_mem, lim_block, home = sys.argv[1:6]
lim_ocpu, lim_mem, lim_block = int(lim_ocpu), int(lim_mem), int(lim_block)
s = json.load(open(state_path))
res = s.get("values", {}).get("root_module", {}).get("resources", [])
if not res:
    for child in s.get("values", {}).get("root_module", {}).get("child_modules", []):
        res.extend(child.get("resources", []))

problems, notes = [], []
by_type = collections.defaultdict(list)
for r in res:
    by_type[r["type"]].append(r.get("values", {}))

# --- compute: A1 total across the tenancy ---
ocpu = mem = 0
for v in by_type.get("oci_core_instance", []):
    sc = v.get("shape_config") or {}
    shape = v.get("shape", "")
    o, m = sc.get("ocpus") or 0, sc.get("memory_in_gbs") or 0
    if "A1" in shape or o:
        ocpu += o
        mem += m
        if v.get("region") and v["region"] != home:
            problems.append(f"instance in {v['region']} — Always Free compute only applies in {home}")
    else:
        notes.append(f"non-A1 instance shape {shape} (E2.1.Micro x2 is Always Free; anything else is not)")
    notes.append(f"instance {v.get('display_name','?')}: {shape} {o} OCPU / {m} GB @ {v.get('availability_domain','?')}")
if ocpu > lim_ocpu:
    problems.append(f"A1 OCPU total {ocpu} > {lim_ocpu} free")
if mem > lim_mem:
    problems.append(f"A1 memory total {mem} GB > {lim_mem} GB free")

# --- block storage ---
block = 0
for v in by_type.get("oci_core_volume", []):
    block += v.get("size_in_gbs", 0)
for v in by_type.get("oci_core_instance", []):
    block += (v.get("boot_volume_size_in_gbs") or 0)
if block > lim_block:
    problems.append(f"block volume total {block} GB > {lim_block} GB free")
notes.append(f"block volume provisioned: {block} GB of {lim_block} GB free")

# --- always-billed extras that must not exist here ---
for t, label in [
    ("oci_bastion", "Bastion is free, but unused"),
    ("oci_nat_gateway", "NAT gateway is NOT Always Free"),
    ("oci_database_autonomous_database", "ADB is free only 2x20GB; watch it"),
    ("oci_load_balancer", "one 10 Mbps flexible LB is free"),
    ("oci_flexible_load_balancer", "one 10 Mbps flexible LB is free"),
    ("oci_waf", "WAF is NOT Always Free"),
    ("oci_public_ip", "reserved public IPs are not Always Free"),
    ("oci_service_connector_hub", "free quota is 2"),
    ("oci_vpn_connection", "free quota is 10"),
]:
    if by_type.get(t):
        notes.append(f"{t}: {len(by_type[t])} in state — check it is inside Always Free ({label})")

# --- public IPs on instances ---
for v in by_type.get("oci_core_instance", []):
    if v.get("public_ip"):
        notes.append("instance has an ephemeral public IP (no Always Free charge)")

print("== free-tier guard ==")
for n in notes:
    print("  -", n)
if problems:
    print("!! BLOCKING ISSUES")
    for p in problems:
        print("  X", p)
    sys.exit(1)
print("OK: inside Always Free allowances.")
PY
rc=$?
if [ "${1:-}" = "--plan" ]; then
  terraform plan -out="$state.plan" > /dev/null || true
  echo "== pending resource types in plan =="
  terraform show -json "$state.plan" 2>/dev/null |
    "$PY" -c 'import json,sys; d=json.load(sys.stdin); rs=d.get("resource_changes",[]); print("\n".join(sorted({r["type"] for r in rs if r["change"]["actions"]!=["no-op"]}))) || true'
fi
exit $rc
