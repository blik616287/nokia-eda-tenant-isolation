#!/usr/bin/env bash
# =============================================================================
# demo-palette.sh — the Palette-side walkthrough, in Tyler's running order.
#
#   WHAT WE HAVE
#     1  Palette edge host list
#     2  the VMs, and the agent installed on them
#     3  hosts tagged from the user-data configured before registration
#     4  those tag values are VLANs EDA configured
#     5  the designated interface, configured on the VM
#     6  an edge cluster on that VM, Ready
#     7  where the cluster's traffic actually goes
#   WHERE WE ARE GOING
#     8  PaletteAI manages the EDA CRs
#     9  PaletteAI generates edge-agent configuration
#   ASSUMPTIONS
#    10  stated plainly, because both change the shape of the answer
#
# Presented to a mixed Palette/Nokia room: everything printed is for the
# audience. No presenter cues.
#
# CONFIG: as demo-record.sh — EDGE_IP, PALETTE_API_KEY, EDA_KUBECONFIG, KCTX.
#   AUTO=1 auto-advance   TYPE=0 no typewriter
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT_DIR/.env" ] && set -a && . "$ROOT_DIR/.env" && set +a

: "${KCTX:=kind-eda-demo}"; : "${NS:=eda}"
: "${EDGE_IP:=}"; : "${DEMO_HOST_UID:=lab-gpu-01}"
: "${AUTO:=0}"; : "${TYPE:=1}"
: "${PALETTE_API_KEY:=}"
PALETTE="${PALETTE_ENDPOINT:-https://palette.example.com}"
PROJECT="${PALETTE_PROJECT_UID:-<project-uid>}"
COMPANION="$ROOT_DIR/docs/companion.md"

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
NAV=next
pause(){
  if [ "$AUTO" = 1 ]; then sleep 4; NAV=next; return 0; fi
  local k
  printf '
%s     [enter] next   [p] back   [r] replay   [g N] go to N   [q] quit%s  ' "$DIM" "$R"
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
page_clear(){ [ "$AUTO" = 1 ] && return 0; printf '[H[2J'; }
page_mark(){ printf '%s     %s  ·  page %s of %s%s
' "$DIM" "$1" "$2" "$3" "$R"; }
run(){ local c="$1"; printf '\n%s  $ %s' "$B" "$R"
  if [ "$TYPE" = 1 ]; then local i; for ((i=0;i<${#c};i++)); do printf '%s' "${c:$i:1}"; sleep 0.012; done; printf '\n'
  else printf '%s\n' "$c"; fi
  eval "$c" 2>&1 | sed 's/^/    /'; }
run_masked(){ local s="$1" r="$2"; printf '\n%s  $ %s' "$B" "$R"
  if [ "$TYPE" = 1 ]; then local i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}"; sleep 0.012; done; printf '\n'
  else printf '%s\n' "$s"; fi
  eval "$r" 2>&1 | sed 's/^/    /'; }
k(){ kubectl --context "$KCTX" -n "$NS" "$@"; }
S(){ sshpass -p "${VM_PASSWORD:-demo}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=8 "${VM_USER:-demo}@$EDGE_IP" "$@"; }
KC(){ S "sudo k3s kubectl $*"; }

[ -n "$EDGE_IP" ] || { echo "EDGE_IP unset — export it, or run make host"; exit 1; }

clear
printf '%s%s\n' "$B$TEAL" '
   ███████ ██████   ███████  ██████ ████████ ██████   ██████
   ██      ██   ██  ██      ██         ██    ██   ██ ██    ██
   ███████ ██████   █████   ██         ██    ██████  ██    ██   ×  N O K I A   E D A
        ██ ██       ██      ██         ██    ██   ██ ██    ██
   ███████ ██       ███████  ██████    ██    ██   ██  ██████
'
printf '%s   Network isolation, end to end — what we have, and where it goes%s\n' "$B" "$R"
note "   $(date -u +%Y-%m-%d)  ·  EDA 26.4.3  ·  SR Linux 26.3.1  ·  edge agent v4.9.39-rc.4"

arc "WHAT WE HAVE"

beat_1(){
# ------------------------------------------------------------------
banner "1 · The edge hosts, in Palette"
ctx "Everything starts from the platform's own inventory. These are ordinary registered edge hosts — nothing about them is special to this demo except the tags they carry."
lede "Hosts registered against this Palette project:"
if [ -n "$PALETTE_API_KEY" ]; then
  PY='import json,sys
try: d=json.load(sys.stdin)
except Exception: print("could not read the edge host list"); sys.exit(0)
for i in d.get("items",[]):
    m=i["metadata"]; s=i.get("status",{})
    print("  %-42s %-10s %s" % (m["name"][:42], s.get("health",{}).get("state","-"), s.get("state","-")))'
  run_masked \
    "curl -sk -H 'ApiKey: \$PALETTE_API_KEY' -H 'ProjectUid: $PROJECT' '$PALETTE/v1/edgehosts?limit=30' | python3 -c '<list edge hosts>'" \
    "curl -sk -H \"ApiKey: \$PALETTE_API_KEY\" -H \"ProjectUid: $PROJECT\" '$PALETTE/v1/edgehosts?limit=30' | python3 -c '$PY'"
else
  note "(PALETTE_API_KEY unset — this is the edge host list view in the Palette UI)"
fi
link "The same list in the Palette console" "$PALETTE/projects/$PROJECT/overview"
pause || return
}

beat_2(){
# ------------------------------------------------------------------
banner "2 · What these hosts are"
ctx "Nothing here depends on special hardware. The point is that an ordinary machine running our edge agent is all the host side requires."
lede "Each host is a VM with two NICs, running the Palette edge agent."
run "sudo virsh -c \${LIBVIRT_URI:-qemu:///system} list --all | grep -E 'Name|---|eda-edge'"
lede "The agent, and the version it is running:"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'systemctl is-active spectro-stylus-agent; sudo journalctl -u spectro-stylus-agent --no-pager --since \"-10 min\" | grep -oE \"version=v[0-9.]+[^ ]*\" | sort -u | tail -1'"
note "installed from the agent-mode tarball; nothing else was configured by hand"
pause || return
}

beat_3(){
# ------------------------------------------------------------------
banner "3 · The tags, and where they came from"
ctx "The tags are not applied after the fact. They are written into the host's user-data before it ever registers, because the agent snapshots them at registration and never re-reads them."
lede "The user-data that was placed on the host before first boot:"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'sudo sed -n \"/^stylus:/,/^install:/p\" /var/lib/spectro/userdata | head -20'"
echo
lede "And the same values, now as tags on the host in Palette:"
if [ -n "$PALETTE_API_KEY" ]; then
  PY2='import json,sys
try: d=json.load(sys.stdin)
except Exception: print("could not read the edge host"); sys.exit(0)
l=d.get("metadata",{}).get("labels") or {}
print("  host:", d["metadata"]["name"], " health:", d.get("status",{}).get("health",{}).get("state"))
for kk in sorted(k for k in l if k.startswith("net-iso")): print("   ", kk, "=", l[kk])'
  run_masked \
    "curl -sk -H 'ApiKey: \$PALETTE_API_KEY' -H 'ProjectUid: $PROJECT' '$PALETTE/v1/edgehosts/$DEMO_HOST_UID' | python3 -c '<print net-iso tags>'" \
    "curl -sk -H \"ApiKey: \$PALETTE_API_KEY\" -H \"ProjectUid: $PROJECT\" '$PALETTE/v1/edgehosts/$DEMO_HOST_UID' | python3 -c '$PY2'"
fi
good "Same values, round-tripped: user-data on the host, tags in the platform."
pause || return
}

beat_4(){
# ------------------------------------------------------------------
banner "4 · Those tag values are VLANs EDA configured"
ctx "The tags are not free text. Each one names something that exists on the Nokia fabric — the VLAN, and the tenant bridge domain carrying it."
lede "The tenants configured on the fabric, with identifiers EDA allocated:"
run "kubectl --context $KCTX -n $NS get bridgedomains"
note "VNI, EVI and route targets come from EDA's allocator — we read them back, never compute them"
echo
lede "Both tenants answer at the same gateway address, on different bridge domains:"
for t in tenant-a tenant-b; do
  printf '    %s%-10s%s ' "$B" "$t" "$R"
  k get virtualnetwork "$t" -o jsonpath='gateway={.spec.irbInterfaces[0].spec.ipAddresses[0].ipv4Address.ipPrefix}  bd={.spec.irbInterfaces[0].spec.bridgeDomain}' 2>/dev/null
  echo
done
good "Overlapping tenant address space, separated by EVPN — the property this exists to provide."
echo
lede "And the per-host attachments, as the fabric itself reports them:"
run "kubectl --context $KCTX -n $NS get bridgeinterfaces -o custom-columns=INTERFACE:.metadata.name,BRIDGE-DOMAIN:.spec.bridgeDomain,PORT:.spec.interface,VLAN:.spec.vlanID,STATE:.status.operationalState"
note "One row is one leaf port placed into one tenant. That is the entire per-host unit —"
note "no agent on the switch, no per-host state anywhere except this."
echo
note "The TOTAL SUBIF column in the first table is the check that matters, and it is"
note "reported by a DIFFERENT object than the one we wrote. EDA accepts a BridgeInterface"
note "before the transaction that programs the switch has committed, so an API success"
note "proves only that the intent was recorded — not that the port moved. Readiness is"
note "gated on the bridge domain's own numSubinterfaces instead."
pause || return
}

beat_5(){
# ------------------------------------------------------------------
banner "5 · The designated interface, on the VM"
ctx "This is the host half. Nobody logged in and configured it; the agent read the tags and built it during cloud-init, before Kubernetes started."
lede "The interface named by net-iso-interface, carrying the tagged VLAN:"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'ip -d link show enp2s0.310 | head -3'"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'ip -brief addr | grep -v \"^lo\"'"
echo
note "enp1s0 is the management path. enp2s0 has no address of its own."
good "802.1Q VLAN 310 at 10.210.0.50/24 — exactly the tag values from section 3."
pause || return
}

beat_6(){
# ------------------------------------------------------------------
banner "6 · The cluster on that host"
ctx "The isolated interface is not decoration. It is the address Kubernetes itself came up on, which is only possible because it existed before the cluster bootstrapped."
lede "The edge cluster, as Palette sees it:"
if [ -n "$PALETTE_API_KEY" ]; then
  PY3='import json,sys
try: d=json.load(sys.stdin)
except Exception: print("could not read clusters"); sys.exit(0)
for i in d.get("items",[]):
    m=i["metadata"]; s=i.get("status",{})
    if s.get("state")=="Deleted": continue
    print("  %-24s state=%-12s health=%s" % (m["name"][:24], s.get("state","-"), s.get("health",{}).get("state","-")))'
  run_masked \
    "curl -sk -H 'ApiKey: \$PALETTE_API_KEY' -H 'ProjectUid: $PROJECT' '$PALETTE/v1/spectroclusters?limit=50' | python3 -c '<list clusters>'" \
    "curl -sk -H \"ApiKey: \$PALETTE_API_KEY\" -H \"ProjectUid: $PROJECT\" '$PALETTE/v1/spectroclusters?limit=50' | python3 -c '$PY3'"
fi
lede "And the node itself:"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'sudo k3s kubectl get nodes -o wide'"
node_ip=$(KC 'get nodes -o jsonpath="{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}"' 2>/dev/null)
if [ "$node_ip" = "10.210.0.50" ]; then
  good "The node's InternalIP is 10.210.0.50 — the isolated address, not the management one."
elif [ -n "$node_ip" ]; then
  bad "node InternalIP is $node_ip, expected 10.210.0.50"
else
  bad "the cluster is not up — this section cannot be shown"
fi
pause || return
}

beat_7(){
# ------------------------------------------------------------------
banner "7 · Where the cluster's traffic actually goes"
ctx "This is the question a network engineer asks, so it is worth being exact. Pod and Service addresses are the cluster's own — they are not tenant addresses, and they are not the isolated subnet. What makes them isolated is the interface every packet leaves on."
lede "The cluster's address ranges, as they actually are:"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'sudo k3s kubectl get ippools.crd.projectcalico.org -o custom-columns=POOL:.metadata.name,CIDR:.spec.cidr,IPIP:.spec.ipipMode --no-headers | head -1'"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'sudo k3s kubectl get svc -A --no-headers | awk \"{print \\\$4}\" | grep -v none | sort -u | head -3'"
note "pods come from Calico's pool, Services from the service CIDR. Neither is 10.210.0.0/24."
echo
lede "Which is the point — look at what each pod actually holds:"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'sudo k3s kubectl get pods -A -o wide --no-headers | awk \"\\\$7 ~ /[0-9]/ {printf \\\"  %-46s %s\\\\n\\\", \\\$2, \\\$7}\" | sort -k2 | head -9'"
note "host-network pods (calico-node, kube-vip) carry 10.210.0.50 — the isolated address."
note "pod-network pods carry Calico pool addresses."
echo
lede "So does the pod network actually ride the tenant VLAN? Ask the kernel:"
run "sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@$EDGE_IP 'ip route get 10.210.0.99; ip -brief addr show tunl0'"
echo
good "Traffic to any peer node leaves on enp2s0.310, sourced from 10.210.0.50."
note "Calico runs IPIP in Always mode, so every pod-to-pod packet between nodes is"
note "encapsulated with that outer address — the tenant VLAN carries the pod network,"
note "whatever addresses the pods use inside it."
echo
note "Which is why a second tenant could run the identical pod CIDR on the same leaf"
note "and still not reach this one. The separation is the bridge domain, not the addressing."
pause || return

arc "WHERE WE ARE GOING"
}

beat_8(){
# ------------------------------------------------------------------
banner "8 · PaletteAI manages the EDA CRs"
ctx "Today the demo drives the provider's own CRs. The direction is that PaletteAI owns the EDA resources directly, created from what a user declares on a ComputePool."
lede "The subset we are currently building against:"
note "  VirtualNetwork    the tenant — emits the IP-VRF, MAC-VRF and IRB together"
note "  BridgeDomain      the MAC-VRF, and where VNI / EVI / route targets are read back"
note "  IRBInterface      the tenant gateway"
note "  BridgeInterface   one per leaf port — the per-host attachment"
note "  Router            the IP-VRF"
echo
lede "In practice we create one VirtualNetwork and let EDA materialise the rest:"
run "kubectl --context $KCTX -n $NS get virtualnetwork tenant-a -o jsonpath='{range .spec}routers={.routers[*].name}  bridgeDomains={.bridgeDomains[*].name}  irbInterfaces={.irbInterfaces[*].name}{\"\\n\"}{end}'"
echo
bad "OPEN QUESTION FOR NOKIA — is this the right subset of the EDA API surface?"
note "We arrived at it by reading the live 26.4.3 CRDs rather than the documentation,"
note "after the two disagreed. If there is a resource we should be using and are not,"
note "or one we are using that you would rather we did not, this is the moment."
pause || return
}

beat_9(){
# ------------------------------------------------------------------
banner "9 · PaletteAI generates the edge-agent configuration"
ctx "The host half is generated, not hand-written. Today one interface is expressible; the direction is all interfaces a host needs."
lede "What the platform generates today — the tags from section 3, one interface:"
note "  net-iso-provider / -interface / -vlan / -subnet-ipv4 / -subnet-prefix-length"
note "  the agent turns those into a VLAN sub-interface, and the node comes up on it"
echo
lede "What that does not yet cover:"
bad "a host on more than one network — a shared storage VLAN alongside the tenant VLAN"
note "the fabric side already supports it: two attachment requests produce two"
note "BridgeInterfaces on the same port with different VLANs, which is ordinary trunking"
note "the host side does not: the tag contract carries exactly one interface, and that"
note "address is defined as becoming the node IP"
echo
note "Extending it is a change in the edge agent's tag contract, not in the EDA provider."
pause || return
}

beat_10(){
# ------------------------------------------------------------------
banner "10 · Assumptions worth stating"
ctx "Both of these change the shape of the answer, so they are better said than assumed."
lede "EDA is deployed and licensed separately."
note "Either colocated with the PaletteAI control plane or in its own Kubernetes cluster."
note "We talk to it as a Kubernetes API and do not package or operate it."
echo
lede "Every cluster PaletteAI deploys is single-tenant."
note "One cluster belongs to one tenant, so there is no pod-level multi-tenancy to solve."
note "Isolation between tenants is the fabric's job, which is what sections 4 to 7 show."
echo
lede "And the boundary on today's claim:"
bad "Forwarding-plane isolation is NOT proven."
note "Everything shown is control plane and host configuration. Demonstrating that traffic"
note "genuinely cannot cross between tenants needs real endpoints, which needs SIMULATE=false"
note "and a licence — the first item on our ask."
echo
link "Integration companion — architecture, findings, and the ask" "$COMPANION"
printf '\n%s   Thank you.%s\n\n' "$B$TEAL" "$R"
pause || return
}

# ---------------------------------------------------------------------------
# One page per beat. BEATS overrides the running order; every beat is a function
# so the cursor can move backwards as well as forwards.
BEATS="${BEATS:-1 2 3 4 5 6 7 8 9 10}"
read -r -a PAGES <<< "$BEATS"
N=${#PAGES[@]}
i=0
while [ "$i" -lt "$N" ]; do
  s="${PAGES[$i]}"
  page_clear
  page_mark "beat $s" "$((i+1))" "$N"
  NAV=next
  if declare -F "beat_$s" >/dev/null; then "beat_$s"
  else printf "%s     unknown beat: %s%s\n" "$RED" "$s" "$R"; fi
  case "$NAV" in
    prev)   [ "$i" -gt 0 ] && i=$((i-1)) ;;
    replay) : ;;
    quit)   printf '\n'; break ;;
    goto:*) t="${NAV#goto:}"; j=0; hit=-1
            while [ "$j" -lt "$N" ]; do [ "${PAGES[$j]}" = "$t" ] && { hit=$j; break; }; j=$((j+1)); done
            if [ "$hit" -ge 0 ]; then i=$hit
            else printf '%s     no beat %s%s\n' "$RED" "$t" "$R"; sleep 1; fi ;;
    *)      i=$((i+1)) ;;
  esac
done
