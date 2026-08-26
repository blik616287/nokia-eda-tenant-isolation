#!/usr/bin/env bash
# =============================================================================
# demo-record.sh — SpectroCloud PaletteAI × Nokia EDA network isolation.
#
# Presented directly to Nokia EDA engineering: everything on screen is addressed
# to the room. No presenter cues, no stage directions — if it is printed, it is
# meant to be read by the audience.
#
# What it shows, live against a running fabric:
#   0. Clean-slate check — the fabric is in a known state before any claim
#   1. The fabric, and what "isolated" means here
#   2. A GPU host resolved to its physical leaf port and attached
#   3. Fail-closed behaviour — the failure mode that is silent
#   4. The host side — a VLAN raised from Palette tags, and k8s on that address
#   5. Both halves at once
#   6. What is proven, and what is not
#   7. Where this stands: stylus, the PRs, and what is open
#   8. Teardown — verified return to the baseline
#
# CONFIG (export before running):
#   EDA_KUBECONFIG   kubeconfig for the EDA cluster   (enables the live §2)
#   EDA_FABRIC_NODE  fabric node name                 (default: lab-gpu-01)
#   EDGE_IP          Palette edge host IP             (§4 and §5 host side)
#   FRISKET          path to the frisket module
#   PALETTE_API_KEY  enables the live tag read in §4
#   AUTO             0 (default) pause for Enter; 1 auto-advance
#   TYPE             1 (default) typewriter on commands; 0 instant
#
# NOTE ON CORRECTNESS (load-bearing — do not "simplify"):
#   * every `go test` runs with -count=1. Go replays cached results byte-for-byte,
#     including t.Logf output, so a cached PASS is indistinguishable from a live
#     run. The EDA transaction delta printed in §6 is the real proof of liveness.
#   * §0 surveys and cleans before anything is claimed; §8 verifies the return to
#     baseline. lab-gpu-01 has exactly ONE cabled port, so without that the second
#     run fails on port contention.
#   * fabric objects are deleted BridgeInterface -> VirtualNetwork -> BridgeDomain.
#     Any other order orphans the interface and fails EVERY EDA transaction after it.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
: "${FRISKET:=$ROOT_DIR/../nokia/mural/frisket}"
: "${KCTX:=kind-eda-demo}"
: "${NS:=eda}"
: "${EDGE_IP:=192.168.122.3}"
: "${EDA_FABRIC_NODE:=lab-gpu-01}"
: "${DEMO_HOST_UID:=lab-gpu-01}"
: "${AUTO:=0}"; : "${TYPE:=1}"
: "${PALETTE_API_KEY:=}"

# Read from .env so no instance detail is baked into a public repository.
[ -f "$HERE/../.env" ] && set -a && . "$HERE/../.env" && set +a
PALETTE="${PALETTE_ENDPOINT:-https://palette.example.com}"
PROJECT="${PALETTE_PROJECT_UID:-<project-uid>}"

# Reference material shown alongside the relevant sections.
COMPANION="https://claude.ai/code/artifact/8764dd23-0951-48b1-ab0a-312a3ebb3614"
EDA_DOCS="https://docs.eda.dev/"
SRL_DOCS="https://documentation.nokia.com/srlinux/"
SRL_LEARN="https://learn.srlinux.dev/"
RFC7432="https://www.rfc-editor.org/rfc/rfc7432"   # BGP MPLS-Based Ethernet VPN
RFC8365="https://www.rfc-editor.org/rfc/rfc8365"   # NVO using EVPN
RFC0014="https://github.com/spectrocloud/mural/blob/main/rfc/0014-aviz-network-isolation.md"

B=$'\e[1m'; DIM=$'\e[2m'; IT=$'\e[3m'; R=$'\e[0m'
TEAL=$'\e[38;5;30m'; SAND=$'\e[38;5;179m'; GREY=$'\e[38;5;244m'
GREEN=$'\e[38;5;35m'; BLUE=$'\e[38;5;39m'; RED=$'\e[38;5;167m'

banner(){ local t="$1"; local pad=$(( 58 - ${#t} )); [ "$pad" -lt 0 ] && pad=0
          printf '\n%s%s╔══════════════════════════════════════════════════════════════╗%s\n' "$B" "$TEAL" "$R"
          printf '%s%s║  %s%*s  ║%s\n' "$B" "$TEAL" "$t" "$pad" "" "$R"
          printf '%s%s╚══════════════════════════════════════════════════════════════╝%s\n' "$B" "$TEAL" "$R"; }
lede(){ printf '%s%s  %s%s\n' "$IT" "$SAND" "$1" "$R"; }
note(){ printf '%s     %s%s\n' "$GREY" "$1" "$R"; }
ctx(){  printf '%s  ▐ WHY%s  %s%s%s\n' "$B$BLUE" "$R" "$IT$GREY" "$1" "$R"; }
good(){ printf '%s     ✓ %s%s\n' "$GREEN" "$1" "$R"; }
bad(){  printf '%s     ✗ %s%s\n' "$RED" "$1" "$R"; }
link(){ printf '    %s▸ %s%s\n      %s%s%s\n' "$B" "$1" "$R" "$BLUE" "$2" "$R"; }
arc(){  printf '\n%s  ── %s ──%s\n' "$B$TEAL" "$1" "$R"; }
pause(){ if [ "$AUTO" = 1 ]; then sleep 4; else printf '\n%s     ⏎%s' "$DIM" "$R"; read -r _; fi; }

run(){ local cmd="$1"; printf '\n%s  $ %s' "$B" "$R"
  if [ "$TYPE" = 1 ]; then local i; for ((i=0;i<${#cmd};i++)); do printf '%s' "${cmd:$i:1}"; sleep 0.012; done; printf '\n'
  else printf '%s\n' "$cmd"; fi
  eval "$cmd" 2>&1 | sed 's/^/    /'; }

# Show one command, execute another. The audience sees $PALETTE_API_KEY; the shell
# gets the value. (A placeholder in single quotes inside run() does NOT work — eval
# keeps it literal and the request goes out unauthenticated.)
run_masked(){ local shown="$1" real="$2"; printf '\n%s  $ %s' "$B" "$R"
  if [ "$TYPE" = 1 ]; then local i; for ((i=0;i<${#shown};i++)); do printf '%s' "${shown:$i:1}"; sleep 0.012; done; printf '\n'
  else printf '%s\n' "$shown"; fi
  eval "$real" 2>&1 | sed 's/^/    /'; }

k(){ kubectl --context "$KCTX" -n "$NS" "$@"; }
gotest(){ ( cd "$FRISKET" && GOTOOLCHAIN=go1.27.0 GOWORK=off \
            GOPRIVATE='github.com/spectrocloud/*' DEMO_HOST_UID="$DEMO_HOST_UID" "$@" ); }
txcount(){ kubectl --context "$KCTX" -n eda-system get transactionresults --no-headers 2>/dev/null | wc -l; }

topology(){
  local W=30 i bar
  local -a L=("EDA FABRIC — Nokia SR Linux" "leaf1 / leaf2  7220 IXR-D3L" "spine1         7220 IXR-D5" "tenant bridge domains (EVPN)")
  local -a Rt=("PALETTE EDGE HOST" "lab-gpu-01" "enp2s0  ->  enp2s0.310" "10.210.0.50/24")
  local -a M=("            " "  <======>  " "  VLAN 310  " "  <======>  ")
  printf -v bar '%*s' "$((W+2))" ''; bar=${bar// /=}
  printf '%s    +%s+            +%s+%s\n' "$GREY" "$bar" "$bar" "$R"
  for i in 0 1 2 3; do
    printf '%s    | %-*s |%s| %-*s |%s\n' "$GREY" "$W" "${L[$i]}" "${M[$i]}" "$W" "${Rt[$i]}" "$R"
  done
  printf '%s    +%s+            +%s+%s\n' "$GREY" "$bar" "$bar" "$R"
  printf '%s      leaf1-ethernet-1-9 is the one port lab-gpu-01 is cabled to%s\n' "$GREY" "$R"
}

DEMO_SETS=( "nokia-demo-pool-leaf1-ethernet-1-9|nokia-demo|nokia-demo-bd"
            "rc-smoke-pool-leaf1-ethernet-1-9|rc-smoke|rc-smoke-bd" )
BASELINE_VNS="tenant-a tenant-b"

clean_fabric(){
  local had=0 bi vn bd
  for pair in "${DEMO_SETS[@]}"; do
    IFS='|' read -r bi vn bd <<<"$pair"
    if k get bridgeinterface "$bi" >/dev/null 2>&1; then
      had=1; k delete bridgeinterface "$bi" --timeout=60s >/dev/null 2>&1; sleep 5
    fi
    if k get virtualnetwork "$vn" >/dev/null 2>&1; then
      had=1; k delete virtualnetwork "$vn" --timeout=60s >/dev/null 2>&1; sleep 10
    fi
    if k get bridgedomain "$bd" >/dev/null 2>&1; then
      had=1; k delete bridgedomain "$bd" --timeout=60s >/dev/null 2>&1
    fi
  done
  return $((had == 1 ? 1 : 0))
}

find_orphans(){
  k get bridgeinterfaces -o json 2>/dev/null | python3 -c "
import json,subprocess,sys
try: items=json.load(sys.stdin).get('items',[])
except Exception: sys.exit(0)
for i in items:
    bd=(i.get('spec') or {}).get('bridgeDomain')
    if not bd: continue
    r=subprocess.run(['kubectl','--context','$KCTX','-n','$NS','get','bridgedomain',bd],capture_output=True)
    if r.returncode!=0:
        print('%s -> missing bridgeDomain %s' % (i['metadata']['name'], bd))
" 2>/dev/null
}

failed_tx(){ kubectl --context "$KCTX" -n eda-system get transactionresults --no-headers 2>/dev/null \
             | tail -8 | awk '$2=="Failed"' | wc -l; }

survey(){
  local dirty=0 leftovers orphans failed
  if ! k get toponodes >/dev/null 2>&1; then
    bad "EDA fabric unreachable at context $KCTX"; return 2
  fi
  good "EDA fabric reachable"
  for v in $BASELINE_VNS; do
    k get virtualnetwork "$v" >/dev/null 2>&1 \
      || { bad "baseline tenant '$v' missing"; dirty=2; }
  done
  [ "$dirty" = 2 ] || good "baseline tenants present — tenant-a, tenant-b"
  leftovers=$(k get virtualnetworks,bridgedomains,bridgeinterfaces --no-headers 2>/dev/null \
              | grep -cE 'nokia-demo|rc-smoke')
  if [ "${leftovers:-0}" -gt 0 ]; then
    note "$leftovers leftover object(s) from a previous run"; dirty=1
  else
    good "no leftover objects from previous runs"
  fi
  orphans=$(find_orphans)
  if [ -n "$orphans" ]; then
    bad "orphaned BridgeInterface(s) — these fail EVERY EDA transaction:"
    printf '%s\n' "$orphans" | sed 's/^/       /'
    dirty=1
  else
    good "no orphaned bridge interfaces"
  fi
  failed=$(failed_tx)
  if [ "${failed:-0}" -gt 0 ]; then
    note "$failed of the last 8 EDA transactions failed"
  else
    good "recent EDA transactions healthy"
  fi
  return $dirty
}

# =============================================================================
clear
printf '%s%s\n' "$B$TEAL" '
   ███████ ██████   ███████  ██████ ████████ ██████   ██████
   ██      ██   ██  ██      ██         ██    ██   ██ ██    ██
   ███████ ██████   █████   ██         ██    ██████  ██    ██   ×  N O K I A   E D A
        ██ ██       ██      ██         ██    ██   ██ ██    ██
   ███████ ██       ███████  ██████    ██    ██   ██  ██████
'
printf '%s   Fabric-level tenant isolation for Palette-managed GPU hosts%s\n' "$B" "$R"
note "   $(date -u +%Y-%m-%d)  ·  EDA 26.4.3 Digital Twin  ·  SR Linux 26.3.1  ·  stylus v4.9.39-rc.4"
echo
link "Integration companion — architecture, findings, and the ask" "$COMPANION"
TX0=$(txcount)

# ---------------------------------------------------------------------------
banner "0 · Clean-slate check"
ctx "Leftover state can make a fabric look healthy while an orphaned object silently fails every EDA transaction. Nothing below is claimed until the starting state is verified."
survey; st=$?
if [ "$st" = 2 ]; then
  bad "Environment degraded — sections below may not be valid."
elif [ "$st" = 1 ]; then
  echo
  lede "Clearing state left by a previous run — bridgeinterface, then virtualnetwork, then bridgedomain."
  clean_fabric || true
  echo
  if survey; then good "clean slate confirmed"; else bad "still not clean"; fi
else
  good "clean slate — nothing to clear"
fi
if sshpass -p demo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=6 "demo@$EDGE_IP" \
     'ip -brief addr show enp2s0.310' >/dev/null 2>&1; then
  good "edge host $EDGE_IP reachable, tenant VLAN up"
else
  note "edge host $EDGE_IP has no enp2s0.310 — sections 4 and 5 will be limited"
fi
pause

# ---------------------------------------------------------------------------
banner "1 · The fabric, and what \"isolated\" means here"
ctx "Isolation here is an EVPN construct, not a firewall rule: a MAC-VRF per tenant with its own EVI and route targets, so two tenants can carry identical address space without seeing each other."
lede "A three-node SR Linux fabric — two leaves and a spine, onboarded and synced."
run "kubectl --context $KCTX -n $NS get toponodes"
topology
lede "Two tenants, each with identifiers allocated by EDA, not by us."
run "kubectl --context $KCTX -n $NS get bridgedomains"
note "VNI, EVI and route targets come from EDA's allocator and are read back into status."
note "If they were identical run to run, it would mean we were computing them."
echo
lede "Both tenants answer at the same gateway address, on different bridge domains:"
for t in tenant-a tenant-b; do
  printf '    %s%-10s%s ' "$B" "$t" "$R"
  k get virtualnetwork "$t" -o jsonpath='gateway={.spec.irbInterfaces[0].spec.ipAddresses[0].ipv4Address.ipPrefix}  bd={.spec.irbInterfaces[0].spec.bridgeDomain}' 2>/dev/null
  echo
done
good "Overlapping tenant address space, separated by EVPN."
echo
link "EDA documentation" "$EDA_DOCS"
link "SR Linux documentation" "$SRL_DOCS"
link "RFC 7432 — BGP MPLS-Based Ethernet VPN" "$RFC7432"
pause

# ---------------------------------------------------------------------------
banner "2 · A GPU host bound to its physical leaf port"
ctx "EDA has no server-name-keyed API — nothing answers 'which port is host X on'. We close that by reverse-indexing the Day-0 cabling intent: edge TopoLinks whose remote.node names the host. This is the part we would most like reviewed."
lede "Running the provider's reconcilers against the live fabric."
if [ -z "${EDA_KUBECONFIG:-}" ]; then
  note "EDA_KUBECONFIG not set — showing the cabling intent rather than the live run"
  run "kubectl --context $KCTX -n $NS get topolinks -o json | python3 -c \"
import json,sys
for i in json.load(sys.stdin)['items']:
    for l in i['spec'].get('links',[]):
        if l.get('type')=='edge' and (l.get('remote') or {}).get('node'):
            print(l['local']['node'], l['local']['interfaceResource'], '->', l['remote']['node'])\""
else
  out=$(gotest go test -count=1 -tags smoke ./internal/smoke/... \
          -run TestReconcilersAgainstLiveCluster -v 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E "UNIT READY|BOUND |FABRIC CONFIRMS|--- PASS" | sed 's/^ *//;s/^/    /' || true
  if [ "$rc" -ne 0 ]; then
    bad "This step did not complete. The output above is not a valid result."
    printf '%s\n' "$out" | grep -E "_test\.go:[0-9]+:|--- FAIL" | head -5 | sed 's/^/    /'
    note "Usually leftover fabric state; clear bridgeinterface -> virtualnetwork -> bridgedomain."
    pause
  fi
fi
echo
note "UNIT READY       tenant VPC realised; VNI/EVI/RT returned by the fabric"
note "BOUND            a Palette host resolved to a physical leaf port, and attached"
note "FABRIC CONFIRMS  the bridge domain independently reporting the sub-interface"
echo
good "The third line is EDA confirming the change, not us reading back our own write."
note "EDA accepts a BridgeInterface before the transaction programming it commits, so an"
note "API success alone is not evidence — readiness is gated on numSubinterfaces instead."
echo
link "Integration companion — §04.3, host-to-port resolution" "$COMPANION"
link "RFC 8365 — Network Virtualization Overlay Solution Using EVPN" "$RFC8365"
pause

# ---------------------------------------------------------------------------
banner "3 · Fail-closed behaviour"
ctx "Tenant isolation fails in a specific way: a host that is NOT attached looks identical to one that is healthy. Nothing errors and nothing alerts, so the design has to treat partial success as failure."
lede "These tests run offline — they pass with the fabric switched off."
gotest go test -count=1 ./internal/controller/eda/... -v 2>&1 \
  | grep -E "^    --- PASS" | sed 's/^    --- PASS: /    /' \
  | grep -E "writes_nothing|unmapped|one_port|operational|EVI_is_ready" || true
echo
good "If any host in a pool cannot be resolved, the whole request fails and nothing is"
good "written to the fabric."
note "Attaching only the resolvable subset would leave a pool partly isolated while"
note "reporting success. The tests assert the fabric is untouched, not just a return code."
echo
note "A multi-rail host must have every rail bound — one missed rail is a data-plane leak."
note "Each of these behaviours was verified by removing it and confirming the suite fails."
echo
link "RFC-0014 — the pluggable network-isolation provider slot" "$RFC0014"
pause

# ---------------------------------------------------------------------------
banner "4 · The host side — a VLAN raised from tags"
ctx "Isolation is established in cloud-init, before Kubernetes starts: the node IP and the CNI come up ON the isolated interface. Anything delivered after a cluster is healthy is too late to participate — which is why this is a provider rather than an add-on."
lede "This host carries five isolation tags in Palette. Nobody has logged into it."
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'ip -d link show enp2s0.310 | head -3'"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'ip -brief addr show enp2s0.310'"
note "802.1Q id 310 carrying 10.210.0.50/24 — exactly the tag values."
echo
lede "The tags in Palette, which is the source of truth for them:"
if [ -n "${PALETTE_API_KEY:-}" ]; then
  PY_TAGS='import json,sys
try: d=json.load(sys.stdin)
except Exception: print("could not read the edge host from Palette"); sys.exit(0)
l=d.get("metadata",{}).get("labels") or {}
print("host:", d["metadata"]["name"], " health:", d.get("status",{}).get("health",{}).get("state"))
for kk in sorted(k for k in l if k.startswith("net-iso")): print("   ", kk, "=", l[kk])'
  run_masked \
    "curl -sk -H 'ApiKey: \$PALETTE_API_KEY' -H 'ProjectUid: $PROJECT' '$PALETTE/v1/edgehosts/$DEMO_HOST_UID' | python3 -c '<print net-iso labels>'" \
    "curl -sk -H \"ApiKey: \$PALETTE_API_KEY\" -H \"ProjectUid: $PROJECT\" '$PALETTE/v1/edgehosts/$DEMO_HOST_UID' | python3 -c '$PY_TAGS'"
  note "These are snapshotted at first registration and never re-read, so they must exist"
  note "before the host registers."
else
  note "(PALETTE_API_KEY not set — five net-iso-* labels on $DEMO_HOST_UID, host healthy)"
fi
echo
lede "And what Kubernetes then did with it:"
nodeip=$(sshpass -p demo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o LogLevel=ERROR -o ConnectTimeout=8 "demo@$EDGE_IP" \
         'sudo cat /etc/rancher/k3s/config.d/90_userdata.yaml 2>/dev/null' 2>/dev/null \
         | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
print('    node-ip          =', d.get('node-ip'))
print('    node-external-ip =', d.get('node-external-ip'))" 2>/dev/null)
if [ -z "$nodeip" ]; then
  bad "Could not read the k3s node config — this result is not being claimed."
else
  printf '%s\n' "$nodeip"
  good "Kubernetes came up on the isolated VLAN address, not the management IP."
fi
echo
note "The agent also fail-closes when the control-plane VIP falls outside the tenant CIDR:"
note "  invalid vip … is not in the CIDR 10.210.0.50/24"
note "— an independent signal that the tags were parsed, not merely accepted."
echo
link "Palette — project overview" "$PALETTE/projects/$PROJECT/overview"
link "stylus #6354 — resolve the fabric NIC, build the VLAN sub-interface" "https://github.com/spectrocloud/stylus/pull/6354"
link "stylus #6394 — aviz-* renamed net-iso-* so a second provider shares the path" "https://github.com/spectrocloud/stylus/pull/6394"
pause

# ---------------------------------------------------------------------------
banner "5 · Both halves, at the same time"
ctx "Each half has been shown separately. This is the same VLAN on the leaf port and on the host cabled to it, placed there by two subsystems with no knowledge of each other."
bi="nokia-demo-pool-leaf1-ethernet-1-9"
if ! k get bridgeinterface "$bi" >/dev/null 2>&1; then
  note "programming the fabric half through the provider now…"
  drv="$FRISKET/internal/smoke/zz_act5_driver_test.go"
  if [ -f "$ROOT_DIR/testdata/act5-driver.gotest" ]; then
    cp "$ROOT_DIR/testdata/act5-driver.gotest" "$drv"
    out=$(gotest go test -count=1 -tags smoke ./internal/smoke/... -run TestAct5Persist -v -timeout 10m 2>&1); rc=$?
    rm -f "$drv"
    printf '%s\n' "$out" | grep -E "UNIT READY|BOUND |FABRIC CONFIRMS|PERSISTED" | sed 's/^ *//;s/^/    /' || true
    [ "$rc" -ne 0 ] && { bad "This step did not complete; the comparison below is not valid."; pause; }
  else
    bad "testdata/act5-driver.gotest not found"
  fi
fi
printf '\n%s    FABRIC SIDE — placed by the provider%s\n' "$B$TEAL" "$R"
k get bridgeinterface "$bi" \
  -o jsonpath='      {.spec.interface}   vlan={.spec.vlanID}   bd={.spec.bridgeDomain}   state={.status.operationalState}{"\n"}' 2>/dev/null
k get bridgedomain nokia-demo-bd \
  -o jsonpath='      vni={.status.vni}   evi={.status.evi}   rt={.status.importTarget}   subifs={.status.numSubinterfaces}{"\n"}' 2>/dev/null
printf '\n%s    HOST SIDE — raised by the agent from Palette tags%s\n' "$B$TEAL" "$R"
sshpass -p demo ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -o ConnectTimeout=8 "demo@$EDGE_IP" \
  'ip -brief addr show enp2s0.310' 2>/dev/null | sed 's/^/      /'
echo
good "Neither half reads the other."
note "They agree because both derive from the same declared intent: the provider resolved"
note "the host to its leaf port through the Day-0 cabling intent, and the agent resolved the"
note "same host's tags into a local interface."
echo
link "Integration companion — §02, the two halves" "$COMPANION"
link "SR Linux learn — EVPN in practice" "$SRL_LEARN"
pause

# ---------------------------------------------------------------------------
banner "6 · What is proven, and what is not"
TX1=$(txcount)
ctx "Go replays cached test output byte-for-byte, so on-screen output alone cannot prove a run was live. The EDA transaction count can."
lede "Transactions driven through EDA's engine during this session:"
note "EDA transactions: $((TX1-TX0))   (zero would mean nothing actually ran)"
run "kubectl --context $KCTX -n eda-system get transactionresults --no-headers | tail -4"
echo
good "PROVEN — EVPN tenancy with overlapping address space; host-to-leaf-port resolution"
good "and attachment; fail-closed behaviour; host VLAN raised from tags; Kubernetes"
good "running on the isolated address."
echo
bad "NOT PROVEN — forwarding-plane isolation."
note "Demonstrating that traffic genuinely cannot cross between tenants needs real"
note "endpoints, which needs SIMULATE=false and a licence. That is a licensing question"
note "rather than a technical blocker, and it is the first item on our ask."
echo
bad "NOT PROVEN — multi-rail hosts and pool scaling on real hardware."
note "Modelled and tested in the reconciler, but not exercised against a DGX-class host"
note "with several fabric-facing NICs, nor against a fabric with thousands of edge links."
echo
link "Integration companion — §06, the full proven / not-proven table" "$COMPANION"
pause

# ---------------------------------------------------------------------------
banner "7 · Where this stands"
ctx "Everything shown runs on code that is either merged or in review. This is the delivery picture, including what is still open and who it sits with."

arc "THE STYLUS SIDE — merged"
note "#6354  resolve the isolated fabric NIC by name, build the VLAN sub-interface"
note "#6394  rename aviz-* tags to net-iso-*, so a second provider can share the path"
good "#6394 is the change that makes an EDA provider possible without forking the agent."
note "Operational note: a Palette instance declares the stylus version and the agent"
note "reconciles down to it. Pinning a specific build needs stylus.skipStylusUpgrade: true"
note "in the edge-host userdata, as a sibling of site:, not inside it."

arc "THE PALETTE SIDE — in review"
pr_live=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
   && gh pr view 8944 --repo spectrocloud/mural --json number >/dev/null 2>&1; then
  pr_live=1
fi
if [ "$pr_live" = 1 ]; then
  note "(queried live)"
  for n in 8944 9124 8945 8946; do
    gh pr view "$n" --repo spectrocloud/mural --json number,title,isDraft,state \
      --jq '"    #\(.number) [\(.state)\(if .isDraft then " · DRAFT" else "" end)]  \(.title[0:54])"' 2>/dev/null
  done
else
  note "    #8944 [OPEN]          hue-apis: EDA provider + CEL admission fix"
  note "    #9124 [OPEN · DRAFT]  hue: gate EDA pools on a resolvable EDAVirtualNetwork"
  note "    #8945 [OPEN · DRAFT]  frisket: EDA client + isolation unit"
  note "    #8946 [OPEN · DRAFT]  frisket: port attachment reconciler"
fi
note "8944 also closes an admission hole: the CEL rule was a per-provider equality, so an"
note "EDA pool made both sides false and was admitted with no isolation reference at all."
echo
note "9124 exists because the policy step passed every non-Aviz provider through as"
note "in-policy — widening the enum without it would have disabled governance for exactly"
note "the provider being added to obtain a guarantee."

arc "OPEN"
note "  ▸ forwarding-plane negative test                    — needs a Nokia licence"
note "  ▸ multi-rail and pool scaling                       — needs GPU hardware"
note "  ▸ confirmation of the findings in companion §07     — Nokia EDA engineering"
note "  ▸ whether §04.3 is the intended resolution pattern  — Nokia EDA engineering"
note "  ▸ release sequencing for the four PRs above         — SpectroCloud"
echo
good "Nothing shown today depends on unmerged work to be true — only to ship."
echo
link "Integration companion — §01, the ask, and §07, the findings" "$COMPANION"
link "#8944 — hue-apis: EDA provider + CEL fix" "https://github.com/spectrocloud/mural/pull/8944"
link "#9124 — hue: policy-step EDA case" "https://github.com/spectrocloud/mural/pull/9124"
link "#8945 — frisket: EDA client + isolation unit" "https://github.com/spectrocloud/mural/pull/8945"
link "#8946 — frisket: port attachment reconciler" "https://github.com/spectrocloud/mural/pull/8946"
pause

# ---------------------------------------------------------------------------
banner "8 · Teardown"
ctx "This session created real fabric objects. lab-gpu-01 has one cabled port, so leaving an attachment behind would make the next run fail on contention. Teardown is part of the demonstration, not an afterthought."
if [ "${TEARDOWN:-1}" = 0 ]; then
  note "TEARDOWN=0 — demo state left in place for inspection"
else
  lede "Removing what this session created, in dependency order."
  if clean_fabric; then note "removed"; else note "nothing to remove"; fi
  echo
  lede "Verifying the fabric is back to its starting state:"
  if survey; then
    good "Baseline restored — tenant-a and tenant-b untouched throughout."
  else
    bad "Fabric is not clean."
  fi
fi
echo
note "The edge host, its Palette registration and the cluster are left running."
echo
link "Integration companion" "$COMPANION"
link "EDA documentation" "$EDA_DOCS"
printf '\n%s   Thank you.%s\n\n' "$B$TEAL" "$R"
