#!/usr/bin/env bash
# =============================================================================
# create-profile.sh — build the cluster profile this demo needs, from the files
# in profile/, and publish it.
#
# The profile is three packs and nothing else: OS, k3s, Calico. Addons are not
# merely unnecessary here, they fail — a single-node edge cluster's only node is
# the control plane and carries node-role.kubernetes.io/control-plane:NoSchedule,
# so any chart without a toleration for it never schedules. Removing the taint
# does not help; the stylus operator re-applies it every ~2 minutes.
#
# WHAT IS INSTANCE-SPECIFIC
#   packUid and registryUid identify packs *in your Palette instance*. The ones
#   recorded in profile/profile.json are ours and will not resolve in yours.
#   Override them in .env, or read them off any existing edge-native profile:
#
#     curl -sk -H "ApiKey: $PALETTE_API_KEY" -H "ProjectUid: $PALETTE_PROJECT_UID" \
#       "$PALETTE_ENDPOINT/v1/clusterprofiles/<an-existing-uid>" \
#     | python3 -c 'import json,sys
#     for p in json.load(sys.stdin)["spec"]["published"]["packs"]:
#         print(p["layer"], p["name"], p["version"], p["packUid"], p["registryUid"])'
#
# The pack VERSIONS in profile.json are what this demo was verified against.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

: "${PROFILE_NAME:=edge-eda-minimal}"
for v in PALETTE_ENDPOINT PALETTE_API_KEY PALETTE_PROJECT_UID; do
  [ -n "${!v:-}" ] || { echo "$v is not set — see .env.example" >&2; exit 1; }
done

body=$(python3 - "$ROOT" "$PROFILE_NAME" <<'PY'
import json, os, sys
root, name = sys.argv[1], sys.argv[2]
man = json.load(open(os.path.join(root, "profile", "profile.json")))
packs = []
for p in man["packs"]:
    e = {"name": p["name"], "type": p["type"], "layer": p["layer"],
         "version": p["version"], "tag": p["version"],
         # tag must be the concrete version: Palette validates `tag` as the
         # version on create and rejects a channel like "2.1.x".
         "packUid":     os.environ.get("PACK_UID_" + p["layer"].upper(), p["packUid"]),
         "registryUid": os.environ.get("REGISTRY_UID", p["registryUid"])}
    if p.get("values"):
        e["values"] = open(os.path.join(root, "profile", p["values"])).read()
    packs.append(e)
print(json.dumps({"metadata": {"name": name,
                               "description": "Edge-native profile for the Nokia EDA tenant-isolation demo: OS, k3s, Calico."},
                  "spec": {"version": "1.0.0",
                           "template": {"type": "cluster", "cloudType": man["cloudType"], "packs": packs}}}))
PY
)

uid=$(curl -sk -X POST -H "ApiKey: $PALETTE_API_KEY" -H "ProjectUid: $PALETTE_PROJECT_UID" \
        -H "Content-Type: application/json" -d "$body" \
        "$PALETTE_ENDPOINT/v1/clusterprofiles" | python3 -c 'import json,sys
d=json.load(sys.stdin)
if "uid" not in d: print("CREATE FAILED:", d.get("message", d), file=sys.stderr); raise SystemExit(1)
print(d["uid"])') || exit 1

# Created profiles are drafts. A draft cannot be deployed, and the failure if you
# try is not obviously about publishing, so do it here.
code=$(curl -sk -X PATCH -H "ApiKey: $PALETTE_API_KEY" -H "ProjectUid: $PALETTE_PROJECT_UID" \
         -o /dev/null -w '%{http_code}' "$PALETTE_ENDPOINT/v1/clusterprofiles/$uid/publish")
[ "$code" = "204" ] || { echo "publish returned HTTP $code" >&2; exit 1; }

echo "  created and published $PROFILE_NAME"
echo "  CLUSTER_PROFILE_UID=$uid"
echo ""
echo "  put that in .env, leave PROFILE_VARIABLES empty, then: make host"
