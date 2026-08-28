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
#   THE STORY (1-7, shared verbatim with demo-palette.sh via beats-palette.sh)
#   1. The edge hosts, in Palette
#   2. What these hosts are — VMs we built, running our edge agent
#   3. The tags, and where they came from — user-data written before registration
#   4. Those tag values are VLANs EDA configured
#   5. The designated interface, correctly configured on the VM
#   6. The cluster on that host, and that Palette reports it Running
#   7. Where the cluster's traffic actually goes
#
#   HOW IT WORKS (8-17)
#   8. The fabric, and what "isolated" means here
#   9. A GPU host resolved to its physical leaf port and attached
#  10. Fail-closed behaviour — the failure mode that is silent
#  11. The host side — the node IP, and the VIP contract being enforced
#  12. Both halves at once
#  13. How Palette drives this — the ComputePool path, and what is missing
#  14. Who writes the host's configuration at fleet scale — the bootstrap path
#  15. What is proven, and what is not
#  16. Where this stands: stylus, the PRs, and what is open
#  17. Where we have not agreed — the two open questions
#  18. Teardown — verified return to the baseline
#
# CONFIG (export before running):
#   EDA_KUBECONFIG   kubeconfig for the EDA cluster   (enables the live §9)
#   EDA_FABRIC_NODE  fabric node name                 (default: lab-gpu-01)
#   EDGE_IP          Palette edge host IP             (host-side pages: §5, §6, §11, §12, §14)
#   FRISKET          path to the frisket module
#   PALETTE_API_KEY  enables the live tag read in §3
#   AUTO             0 (default) pause for Enter; 1 auto-advance
#   TYPE             1 (default) typewriter on commands; 0 instant
#
# NOTE ON CORRECTNESS (load-bearing — do not "simplify"):
#   * every `go test` runs with -count=1. Go replays cached results byte-for-byte,
#     including t.Logf output, so a cached PASS is indistinguishable from a live
#     run. The EDA transaction delta printed in §15 is the real proof of liveness.
#   * §0 surveys and cleans before anything is claimed; §18 verifies the return to
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
: "${DEMO_CLUSTER:=${CLUSTER_NAME:-eda-iso-demo}}"
: "${DEMO_MAC:=52:54:00:26:9a:5e}"
: "${AUTO:=0}"; : "${TYPE:=1}"
: "${PALETTE_API_KEY:=}"

# Read from .env so no instance detail is baked into a public repository.
[ -f "$HERE/../.env" ] && set -a && . "$HERE/../.env" && set +a
PALETTE="${PALETTE_ENDPOINT:-https://palette.example.com}"
PROJECT="${PALETTE_PROJECT_UID:-<project-uid>}"

# Reference material shown alongside the relevant sections.
REPO="https://github.com/blik616287/nokia-eda-tenant-isolation"
COMPANION="$REPO/blob/main/docs/companion.md"
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
# One page per section. pause() is the page break: it returns 0 to carry on
# within a section, and non-zero for anything that leaves it, so every call site
# is `pause || return` and the driver below acts on $NAV.
NAV=next
pause(){
  if [ "$AUTO" = 1 ]; then sleep 4; NAV=next; return 0; fi
  local k
  printf '\n%s     [enter] next   [p] back   [r] replay   [g N] go to N   [q] quit%s  ' "$DIM" "$R"
  read -r k
  case "$k" in
    p|P|b|B)      NAV=prev;   return 1 ;;
    r|R)          NAV=replay; return 1 ;;
    q|Q)          NAV=quit;   return 1 ;;
    g\ *|G\ *)    NAV="goto:${k#* }"; return 1 ;;
    [0-9]*)       NAV="goto:$k"; return 1 ;;
    *)            NAV=next;   return 0 ;;
  esac
}
page_clear(){ [ "$AUTO" = 1 ] && return 0; printf '\033[H\033[2J'; }
page_mark(){ printf '%s     %s  ·  page %s of %s%s\n' "$DIM" "$1" "$2" "$3" "$R"; }

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
  local -a L=("EDA FABRIC - Nokia SR Linux" "leaf1 / leaf2  7220 IXR-D3L" "spine1         7220 IXR-D5" "tenant bridge domains (EVPN)")
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
            "|nokia-neighbour|nokia-neighbour-bd"
            "rc-smoke-pool-leaf1-ethernet-1-9|rc-smoke|rc-smoke-bd" )
BASELINE_VNS="tenant-a tenant-b"

clean_fabric(){
  local had=0 bi vn bd
  for pair in "${DEMO_SETS[@]}"; do
    IFS='|' read -r bi vn bd <<<"$pair"
    if [ -n "$bi" ] && k get bridgeinterface "$bi" >/dev/null 2>&1; then
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
              | grep -cE 'nokia-demo|nokia-neighbour|rc-smoke')
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
# Sections are functions so a run can present them in a different order. The
# numbering never changes — only which are run and in what sequence — so a
# cross-reference like "see section 5" stays true whichever cut you use.
#
# Bodies are deliberately NOT re-indented: section 6 contains a heredoc whose
# closing delimiter must stay at column 0.
# =============================================================================

title(){
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
}

sec_0(){
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
  note "edge host $EDGE_IP has no enp2s0.310 — the host-side pages will be limited"
fi
pause || return
}

# The opening seven pages are the Palette-side story, shared verbatim with
# demo-palette.sh so the two cannot drift. beat_N banners itself as "N · …",
# which is why these map one-to-one onto sections 1-7 rather than being renamed.
. "$HERE/beats-palette.sh"
resolve_edge_ip || true   # the DHCP lease moves on every reboot
sec_1(){ beat_1; }
sec_2(){ beat_2; }
sec_3(){ beat_3; }
sec_4(){ beat_4; }
sec_5(){ beat_5; }
sec_6(){ beat_6; }
sec_7(){ beat_7; }

sec_8(){
# ---------------------------------------------------------------------------
banner "8 · The fabric, and what \"isolated\" means here"
ctx "Your node is in nokia-demo. To show what that membership is actually worth, this page creates a second tenant on the same three switches and gives it the IDENTICAL gateway address — then shows what keeps them apart."
topology
lede "Creating a neighbour tenant at the same address as yours:"
if k get virtualnetwork nokia-neighbour >/dev/null 2>&1; then
  note "already on the fabric from earlier in this session"
else
  # Cloned from the host's own tenant so it is genuinely the same shape, with every
  # name made unique -- each name inside the spec becomes a CR of its own, and a
  # collision fails the transaction while leaving a VirtualNetwork that never realises.
  tmp=$(mktemp) || true
  k get virtualnetwork nokia-demo -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
peer=json.loads(json.dumps(d["spec"]).replace("nokia-demo","nokia-neighbour"))
peer["irbInterfaces"][0]["name"]="neighbour-gw"
peer["bridgeDomains"][0]["spec"]["description"]="Second tenant at the identical address"
json.dump({"apiVersion":d["apiVersion"],"kind":d["kind"],
           "metadata":{"name":"nokia-neighbour","namespace":"eda"},"spec":peer}, sys.stdout)' > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then k apply -f "$tmp" 2>&1 | sed 's/^/    /'; sleep 25; else bad "could not clone the tenant"; fi
  rm -f "$tmp"
fi
echo
lede "Your tenant, and its new neighbour:"
run "kubectl --context $KCTX -n $NS get bridgedomains nokia-demo-bd nokia-neighbour-bd -o custom-columns=TENANT:.metadata.name,VNI:.status.vni,EVI:.status.evi,ROUTE-TARGET:.status.importTarget"
echo
lede "And the address each one answers at:"
for t in nokia-demo nokia-neighbour; do
  printf '    %s%-18s%s ' "$B" "$t" "$R"
  k get virtualnetwork "$t" -o jsonpath='gateway={.spec.irbInterfaces[0].spec.ipAddresses[0].ipv4Address.ipPrefix}' 2>/dev/null
  echo
done
echo
good "The same address, on the same fabric, in two different tenants."
note "What separates them is the route target. Route targets decide which VRF imports"
note "whose routes, and these two do not import each other's — so neither network can"
note "learn the other's addresses at all. It is not a filter applied to traffic; the"
note "routes are never exchanged in the first place."
note "Your node sits in nokia-demo. Nothing in nokia-neighbour can reach it and it can"
note "reach nothing there, even though both are using 10.210.0.1. That is the property"
note "this whole integration exists to provide, and it is why a customer's address plan"
note "stops being something anyone else has to be consulted about."
echo
link "EDA documentation" "$EDA_DOCS"
link "SR Linux documentation" "$SRL_DOCS"
link "RFC 7432 — BGP MPLS-Based Ethernet VPN" "$RFC7432"
pause || return
}

sec_9(){
# ---------------------------------------------------------------------------
banner "9 · A GPU host bound to its physical leaf port"
ctx "To put a server into a tenant, something has to know which switch port it is plugged into. There is no API for that question, and the reason is reasonable: EDA models the fabric, and a GPU server is not part of the fabric. What we did was read the cabling records backwards — the Day-0 topology already records that port X connects to host Y, so we searched it by host. It works. Nokia reviewed it and said the record does not belong there, and we agree. The replacement is at the bottom of this page."
note "In plain terms: we needed a phone book from server to switch port, nobody keeps"
note "one, so we read the switch's own wiring list backwards. That works and it is the"
note "wrong place to look it up."

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
  note "What follows is the provider's conformance suite driven against this fabric. It"
  note "creates a throwaway tenant (rc-smoke-*), binds a host to a leaf port, asks the"
  note "fabric to confirm it, then removes everything. The host identifier is a test"
  note "fixture; the fabric node, the leaf port and the VLAN are the real ones."
  out=$(gotest go test -count=1 -tags smoke ./internal/smoke/... \
          -run TestReconcilersAgainstLiveCluster -v 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E "UNIT READY|BOUND |FABRIC CONFIRMS|--- PASS" | sed 's/^ *//;s/^/    /' || true
  if [ "$rc" -ne 0 ]; then
    bad "This step did not complete. The output above is not a valid result."
    printf '%s\n' "$out" | grep -E "_test\.go:[0-9]+:|--- FAIL" | head -5 | sed 's/^/    /'
    note "Usually leftover fabric state; clear bridgeinterface -> virtualnetwork -> bridgedomain."
    pause || return
  fi
fi
echo
note "Reading those three lines:"
echo
note "UNIT READY       the tenant network exists. The VNI, EVI and route target on that"
note "                 line were allocated by EDA and read back — none of them supplied"
note "                 by us. Identical values run to run would mean we had computed them."
note "BOUND            the host was resolved to the one leaf port it is cabled to, and"
note "                 that port placed into the tenant: leaf1, ethernet-1-9, VLAN 310."
note "FABRIC CONFIRMS  a DIFFERENT object — the bridge domain — reporting how many"
note "                 sub-interfaces it now carries. One. That is the fabric agreeing"
note "                 with the request, not the request being read back to itself."
echo
good "Only the third line is evidence."
note "EDA accepts a BridgeInterface before the transaction that programs the switch has"
note "committed. An API success therefore proves the intent was recorded, not that the"
note "port was moved. Readiness is gated on the bridge domain's numSubinterfaces — a"
note "field the live CRDs and the documentation disagree about, and the CRDs win."
echo
note "On the resolution above: your review is that an edge TopoLink should describe the"
note "switch side only, and we accept that. The reverse-index is being replaced by the"
note "leaf port carried directly on the host record — RFC-0021 §4e. What is bound, and"
note "how the fabric confirms it, is unchanged either way."
echo
link "Integration companion — §4.3, host-to-port resolution" "$COMPANION#43-host-to-leaf-port-resolution-the-part-we-are-replacing"
link "RFC 8365 — Network Virtualization Overlay Solution Using EVPN" "$RFC8365"
pause || return
}

sec_10(){
# ---------------------------------------------------------------------------
banner "10 · Fail-closed behaviour"
ctx "This is the failure that worries us most, and it is worth stating before the tests run. When network isolation does not happen, nothing visibly breaks. The server boots, joins its cluster and passes every health check — it simply is not isolated. No error, no alert, and the first person to find out is whoever should not have been able to reach it. So anything less than complete success has to be treated as failure."
note "In plain terms: a lock that silently fails open. The tests below exist to prove"
note "we refuse to write anything at all rather than write half of it."

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
pause || return
}

sec_11(){
# ---------------------------------------------------------------------------
banner "11 · The host side — the node IP, and the VIP contract"
ctx "The switch side is only half of it. The server has to put its own traffic on the matching VLAN, and it has to do that before Kubernetes starts, because the node's address and the pod network both come up on that interface. Anything delivered after the cluster is healthy has missed its moment. That timing is the whole reason this is built into the platform rather than installed onto a running cluster."
note "In plain terms: the machine has to be on the right network before it is a"
note "Kubernetes node at all, so this cannot be something you apply afterwards."

lede "Pages 3 and 5 showed the tags and the interface they built. This is what those"
lede "values then determined, which is the part that cannot be applied afterwards."
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
pause || return
}

sec_12(){
# ---------------------------------------------------------------------------
banner "12 · Both halves, at the same time"
ctx "Both halves have now been shown on their own. Here they are together — the same VLAN on the switch port and on the server plugged into it. The two were put there by different systems that never speak to each other and never read each other's result. They agree because both were told the same thing."
note "In plain terms: two people set the same channel on two radios from the same"
note "written order. If they ever disagreed nothing would break loudly — which is"
note "exactly the silent failure the previous page is about."

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
link "Integration companion — §2, the two halves" "$COMPANION#2-what-we-are-integrating-and-why-it-is-not-trivial"
link "SR Linux learn — EVPN in practice" "$SRL_LEARN"
pause || return
}

sec_13(){
# ---------------------------------------------------------------------------
banner "13 · How Palette drives this — the ComputePool path"
ctx "Everything so far was driven by calling our own code directly, which is not how anyone would actually use this. A user picks some hosts, groups them into a pool, and asks for that pool to be isolated. This page is that path: what a user declares, what it has to turn into, and precisely which link in the chain is not written yet."
note "In plain terms: you have seen the engine run on a test bench. This is where it"
note "connects to the pedal, and one linkage is still missing."

lede "A user does not write EDA intent. They declare isolation on a ComputePool:"
cat <<'YAML' | sed 's/^/    /'
apiVersion: spectrocloud.com/v1alpha1
kind: ComputePool
spec:
  networkIsolation:
    provider: EDA                        # the enum value added by mural#8944
    eda:
      edaVirtualNetwork: tenant-a        # which isolation unit
      subnet: gpu                        # which of its subnets -> access VLAN
YAML
echo
lede "A provider-side watcher turns that into the two CRs you have already seen work:"
note "  EDAVirtualNetwork        the isolation unit — one EDA VirtualNetwork per tenant"
note "  EDAPortAttachmentRequest the per-pool binding — one BridgeInterface per leaf port"
echo
lede "That watcher is the one piece not yet written. The shipped Aviz analogue is the pattern:"
run "sed -n '/^\/\/ ComputePoolReconciler/,/^type ComputePoolReconciler/p' \
  \"\$FRISKET/internal/controller/aviz/computepool_controller.go\" | head -6"
note "the EDA equivalent mirrors it: watch ComputePool, filter provider == EDA,"
note "materialise one EDAPortAttachmentRequest owned by the pool. RFC-0021 item 13."
echo
lede "So the state of the chain, honestly:"
good "EDAVirtualNetwork reconciler        written, tested, running here"
good "EDAPortAttachmentRequest reconciler written, tested, running here"
bad  "ComputePool -> CR watcher           NOT written — the CRs above were created directly"
bad  "provider: EDA on a ComputePool      NOT available — mural#8944 is open, on hold"
echo
note "Nothing shown in sections 1-5 depends on those two. They are what turns a working"
note "integration into something a user can reach from the product."
echo
link "#8944 — the enum, CEL fix and EDANetworkIsolation type" "https://github.com/spectrocloud/mural/pull/8944"
link "#8946 — the attachment reconciler" "https://github.com/spectrocloud/mural/pull/8946"
pause || return
}

sec_14(){
# ---------------------------------------------------------------------------
banner "14 · Who writes the host's configuration, at fleet scale"
ctx "Everything so far assumed the server already knew its own isolation settings. On this machine, someone put that file there by hand before it ever registered. That is honest for one server and impossible for a thousand — and it is also circular, because you cannot configure a machine's main network connection by talking to it over that same connection. This page is the way out of the circle."
note "In plain terms: the machine has to be told which network it belongs to before it"
note "can be reached on that network. Something else has to answer that, at boot."

lede "Everything a booting host presents about itself — one value:"
run "echo $DEMO_MAC"
note "In production this is not even a lookup. The leaf's DHCP relay inserts Option 82"
note "circuit-id — the port the request arrived on — so the fabric names the port and"
note "nothing has to resolve the host at all. The Digital Twin has no forwarding plane,"
note "so there is no relay here; we key on MAC from inventory. The derivation is the same."
echo
lede "What it is served, derived live from the fabric:"
run_masked "./scripts/provision-endpoint.py --once $DEMO_MAC --explain" \
           "$HERE/provision-endpoint.py --once $DEMO_MAC --explain"
note "Nothing per-host is authored. Two of those lines are ours to change and we have"
note "said so: the cabling read becomes the leaf port on the host record (RFC-0021 §4e),"
note "and pool-to-tenant is what the ComputePool watcher will own (RFC-0021 item 13)."
echo
lede "Against the values actually on the running host:"
a=$("$HERE/provision-endpoint.py" --once "$DEMO_MAC" 2>/dev/null | sed -n '/net-iso/p')
b=$(sshpass -p "${VM_PASSWORD:-demo}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=8 "${VM_USER:-demo}@$EDGE_IP" \
      'sudo sed -n "/net-iso/p" /var/lib/spectro/userdata' 2>/dev/null)
if [ -n "$a" ] && [ "$a" = "$b" ]; then
  printf '%s\n' "$a" | sed 's/^ *//;s/^/      /'
  good "Identical. Derived from the fabric, not copied from the host."
elif [ -z "$a" ]; then
  note "The tenant is not on the fabric — section 4 creates it, and section 18 removes it."
else
  bad "The two do not match."
fi
echo
lede "A service returning the right answer could be reciting it. Ask for a different tenant:"
run_masked "./scripts/provision-endpoint.py --once $DEMO_MAC --tenant tenant-a" \
           "$HERE/provision-endpoint.py --once $DEMO_MAC --tenant tenant-a 2>&1 | tail -1"
good "Fail closed. tenant-a's subnet is read live from its IRB, the reserved address is"
good "not inside it, and no configuration is served at all."
echo
good "CLOSED — per-host configuration is no longer authored anywhere. Every machine boots"
good "the same image and is told what it is."
bad "NOT CLOSED — the transport. A production host gets this over PXE/iPXE or an"
bad "out-of-band installer; this is plain HTTP on the management network."
bad "NOT CLOSED — IPAM. The tenant subnet is the fabric's; which address inside it belongs"
bad "to a host is a decision nothing owns yet, so it is carried as a reservation."
echo
note "DPU addressing arrives over DHCP and removes this circularity rather than routing"
note "around it. It is the better answer and it is yours — companion §8 for why we treat"
note "it as an optimisation rather than a prerequisite."
echo
link "Integration companion — §5.1, the bootstrap dependency" "$COMPANION#51-what-we-configure-and-what-we-deliberately-do-not"
link "The same ground in full — make demo-bootstrap" "$REPO/blob/main/scripts/demo-bootstrap.sh"
pause || return
}

sec_15(){
# ---------------------------------------------------------------------------
banner "15 · What is proven, and what is not"
TX1=$(txcount)
ctx "Everything up to here has been a claim. This is the accounting, including a caution about the evidence itself: Go replays a cached test result exactly, its timing included, so a green result on screen does not prove anything ran just now. The fabric's own transaction counter does, because nothing on this side can fake it."
note "In plain terms: do not trust the test output, trust the count the switches keep."
note "Zero would mean this whole session touched nothing, whatever the screen said."

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
link "Integration companion — §6, the full proven / not-proven table" "$COMPANION#6-what-is-proven-and-what-is-not"
pause || return
}

sec_16(){
# ---------------------------------------------------------------------------
banner "16 · Where this stands"
ctx "Nothing here was staged for today. Everything shown runs on code that is either already merged or open in review, and this page says which is which, what is still unwritten, and whose desk each open item sits on."
note "In plain terms: nothing you were shown depends on unmerged work to be TRUE."
note "It depends on unmerged work to SHIP, and those are different problems."


arc "THE STYLUS SIDE — merged"
note "#6354  resolve the isolated fabric NIC by name, build the VLAN sub-interface"
note "#6394  rename aviz-* tags to net-iso-*, so a second provider can share the path"
good "#6394 is the change that makes an EDA provider possible without forking the agent."

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
note "9124 is the matching one: the policy step passed every non-Aviz provider through"
note "as in-policy, so widening the enum without it would have disabled governance for"
note "exactly the provider being added to obtain a guarantee."

arc "OPEN"
note "  ▸ forwarding-plane negative test                    — needs a Nokia licence"
note "  ▸ multi-rail and pool scaling                       — needs GPU hardware"
note "  ▸ confirmation of the findings in companion §7      — Nokia EDA engineering"
note "  ▸ release sequencing for the four PRs above         — SpectroCloud"
echo

good "Nothing shown today depends on unmerged work to be true — only to ship."
echo
link "Integration companion — §1, the ask, and §7, the findings" "$COMPANION#1-the-ask-up-front"
link "#8944 — hue-apis: EDA provider + CEL fix" "https://github.com/spectrocloud/mural/pull/8944"
link "#9124 — hue: policy-step EDA case" "https://github.com/spectrocloud/mural/pull/9124"
link "#8945 — frisket: EDA client + isolation unit" "https://github.com/spectrocloud/mural/pull/8945"
link "#8946 — frisket: port attachment reconciler" "https://github.com/spectrocloud/mural/pull/8946"
pause || return
}

sec_17(){
# ---------------------------------------------------------------------------
banner "17 · Where we have not agreed"
ctx "Two of these, and raising them rather than smoothing them over: both change what gets built, and both are cheaper to settle in this room than during an integration."
good "SETTLED, IN YOUR FAVOUR — where a host's switch port is recorded."
note "We were populating remote.node on an edge TopoLink purely as a lookup key. You"
note "told us that is not what an edge link is for, and your own schema says the same:"
echo
note "    kubectl explain topolink.spec"
note "    \"Creating a link with only A specified will create an edge interface.\""
echo
note "The empty remote.interfaceResource was the tell — there is no fabric object on"
note "that side, because a GPU server is not a TopoNode. We were reading topology"
note "intent as a server inventory. It has been changed: the leaf port moves onto the"
note "Palette host record and the provider takes it directly. RFC-0021 §4e."
echo
bad "STILL OPEN — who configures east/west on the host."
note "Your position, as we understood it from the sync — please correct this if we"
note "have it wrong, because we would rather be corrected than build against it:"
note "an AI host needs at least two networks configured, north/south plus east/west"
note "for RDMA and storage, with smart NICs such as BlueField and ConnectX in scope."
echo
note "Ours, and the reason for it: our node preparation deliberately leaves the rail"
note "NICs with no addresses at all, and NV-IPAM with Multus assigns them per workload"
note "inside the cluster. That tooling already owns rail addressing — configuring the"
note "same interfaces from the edge agent would collide with it rather than complete it."
echo
good "Most of the surface is not in dispute. Every rail port has to sit in the right"
good "tenant's VRF on the fabric, that part is ours, it is modelled one BridgeInterface"
good "per port, and it is what this demo has been showing you all along."
note "So the open question is narrower than it first sounds: does anything need to"
note "configure rail interfaces ON THE HOST beyond that, and if so, whose job is it?"
echo
note "Storage is the same question with the sign reversed: a shared multi-tenant storage"
note "VLAN needs addresses that do NOT overlap, the opposite of the property this demo"
note "relies on. The fabric side already handles a host on two networks; the host-side"
note "tag contract carries exactly one interface, so that half is not expressible yet."
echo
link "Integration companion — §5.1, scope, and §5.2, networks beyond the tenant VLAN" "$COMPANION#51-what-we-configure-and-what-we-deliberately-do-not"
echo
pause || return
}

sec_18(){
# ---------------------------------------------------------------------------
banner "18 · Teardown"
ctx "This session created real objects on a real fabric, so it has to remove them. There is a practical reason as well as a tidy one: this server has exactly one cabled port, and an attachment left behind would make the next run fail over it. Putting the fabric back is part of the demonstration — a change you cannot cleanly reverse is not one you should be making automatically."
note "In plain terms: we are showing you the undo, because a system that only knows"
note "how to create things is not finished."

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
pause || return
}

# ---------------------------------------------------------------------------
# Default is the full run in numeric order. Override SECTIONS to change the cut;
# `make demo-tyler` leads with the ComputePool path.
SECTIONS="${SECTIONS:-0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18}"

title
[ "$AUTO" = 1 ] || { printf '\n%s     [enter] begin%s  ' "$DIM" "$R"; read -r _; }

read -r -a PAGES <<< "$SECTIONS"
N=${#PAGES[@]}
i=0
while [ "$i" -lt "$N" ]; do
  s="${PAGES[$i]}"
  page_clear
  page_mark "section $s" "$((i+1))" "$N"
  NAV=next
  if declare -F "sec_$s" >/dev/null; then "sec_$s"
  else printf "%s     unknown section: %s%s\n" "$RED" "$s" "$R"; fi
  case "$NAV" in
    prev)   [ "$i" -gt 0 ] && i=$((i-1)) ;;
    replay) : ;;
    quit)   printf '\n'; break ;;
    goto:*) t="${NAV#goto:}"; j=0; hit=-1
            while [ "$j" -lt "$N" ]; do [ "${PAGES[$j]}" = "$t" ] && { hit=$j; break; }; j=$((j+1)); done
            if [ "$hit" -ge 0 ]; then i=$hit
            else printf '%s     no section %s in this cut%s\n' "$RED" "$t" "$R"; sleep 1; fi ;;
    *)      i=$((i+1)) ;;
  esac
done
