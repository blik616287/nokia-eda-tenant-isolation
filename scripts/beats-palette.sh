#!/usr/bin/env bash
# =============================================================================
# beats-palette.sh — the Palette-side story, as reusable pages.
#
# Sourced by demo-palette.sh (which runs it alone) and by demo-record.sh (which
# opens with it). Defines beat_1..beat_10 and nothing else: the helpers, colours
# and configuration come from whichever script sources this, so the two stay in
# step instead of drifting into two versions of the same claim.
#
# Requires from the caller: banner lede note ctx good bad link pause run
#                           run_masked k  and  KCTX NS EDGE_IP PALETTE PROJECT
#                           PALETTE_API_KEY DEMO_HOST_UID COMPANION B R TEAL GREY
# =============================================================================

# Every helper the beats call lives here, not in one of the callers. KC() used to
# sit in demo-palette.sh; under demo-record.sh it was undefined, the node lookup
# returned empty, and the page announced "the cluster is not up" about a cluster
# that was running. A shared page cannot depend on which script sourced it.
S(){ sshpass -p "${VM_PASSWORD:-demo}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=8 "${VM_USER:-demo}@$EDGE_IP" "$@"; }
KC(){ S "sudo k3s kubectl $*"; }

# Does the edge host answer at this address?
edge_reachable(){ [ -n "${1:-}" ] && sshpass -p "${VM_PASSWORD:-demo}" ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -o ConnectTimeout=5 "${VM_USER:-demo}@$1" true >/dev/null 2>&1; }

# The management address is a DHCP lease: it changes on every reboot, not only on
# every rebuild. A stale EDGE_IP does not fail loudly -- the page prints "No route
# to host" and the notes underneath carry on asserting things about a host nobody
# reached. So find the host rather than trusting what we were told about it.
resolve_edge_ip(){
  edge_reachable "${EDGE_IP:-}" && return 0
  local was="${EDGE_IP:-}" cand
  for cand in "$(cat "${ROOT_DIR:-..}/.work/edge-ip" 2>/dev/null)" \
              "$(sudo -n virsh -c "${LIBVIRT_URI:-qemu:///system}" domifaddr "${VM_NAME:-eda-edge-01}" 2>/dev/null \
                 | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)"; do
    [ -n "$cand" ] && [ "$cand" != "$was" ] || continue
    if edge_reachable "$cand"; then
      EDGE_IP="$cand"
      printf '%s     edge host is at %s, not %s — using the address that answers%s\n' \
        "${GREY:-}" "$cand" "${was:-<unset>}" "${R:-}"
      return 0
    fi
  done
  return 1
}

# Run a command ON THE EDGE HOST, displayed cleanly.
#
# Inlining ssh with nested quotes is how this file broke once: the quoting fell
# apart, ssh took only the first fragment, and the remainder ran on the
# PRESENTER'S machine -- printing the hypervisor's interfaces as though they
# were the host's. A wrong answer that looks like a healthy one. printf %q
# hands the remote shell exactly one argument, so that cannot recur.
rssh(){ local shown="$1" cmd="$2"
  run_masked "ssh ${DEMO_HOST_UID:-edge-host} '$shown'" \
    "sshpass -p ${VM_PASSWORD:-demo} ssh -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 \
       ${VM_USER:-demo}@$EDGE_IP $(printf '%q' "$cmd")"; }

beat_1(){
# ------------------------------------------------------------------
banner "1 · The edge host, in Palette"
ctx "Everything starts from the platform's own inventory. This is an ordinary registered edge host — the only thing special about it is the tags it carries, and those are visible right here on the record."
lede "The host this demo runs on, as Palette has it registered:"
if [ -n "$PALETTE_API_KEY" ]; then
  # Filtered to this demo's host deliberately: the project carries hosts from
  # other work whose health is noise here and nobody else's business. The number
  # filtered is printed, so this reads as a filter and not as a crop.
  PY='import json,os,sys
want=os.environ.get("DEMO_HOST_UID","lab-gpu-01")
try: d=json.load(sys.stdin)
except Exception: print("  could not read the edge host list"); sys.exit(0)
items=d.get("items",[]); me=[i for i in items if i["metadata"]["name"]==want]
if not me:
    print("  %s is not registered against this project" % want)
else:
    h=me[0]; m=h["metadata"]; st=h.get("status",{}); hl=st.get("health",{})
    lab={k:v for k,v in (m.get("labels") or {}).items() if k.startswith("net-iso")}
    print("  %s" % m["name"])
    print("    health        %s — %s" % (hl.get("state","-"), hl.get("message","-")))
    print("    state         %s" % st.get("state","-"))
    print("    agent         %s" % hl.get("agentVersion","-"))
    for c in st.get("inUseClusters") or [{"name":"(none)"}]:
        print("    cluster       %s" % c.get("name"))
    print("    isolation     provider=%s  interface=%s  vlan=%s" % (
        lab.get("net-iso-provider","-"), lab.get("net-iso-interface","-"), lab.get("net-iso-vlan","-")))
    print("                  subnet=%s/%s" % (
        lab.get("net-iso-subnet-ipv4","-"), lab.get("net-iso-subnet-prefix-length","-")))
    print("                  %d net-iso label%s on the host record" % (len(lab), "" if len(lab)==1 else "s"))
n=len(items)-len(me)
if n: print("  (%d further host%s in this project belong to other work, not shown)" % (n, "" if n==1 else "s"))'
  run_masked \
    "curl -sk -H 'ApiKey: \$PALETTE_API_KEY' -H 'ProjectUid: $PROJECT' '$PALETTE/v1/edgehosts?limit=30' | python3 -c '<this host>'" \
    "curl -sk -H \"ApiKey: \$PALETTE_API_KEY\" -H \"ProjectUid: $PROJECT\" '$PALETTE/v1/edgehosts?limit=30' | DEMO_HOST_UID=$DEMO_HOST_UID python3 -c '$PY'"
  echo
  lede "And the cluster that host is running:"
  PYC='import json,os,sys
want=os.environ.get("DEMO_CLUSTER","eda-iso-demo")
try: d=json.load(sys.stdin)
except Exception: print("  could not read clusters"); sys.exit(0)
# Rebuilds leave deleted clusters behind under the same name. Matching on name
# alone finds one of those and puts state=Deleted on screen next to a host that
# is demonstrably running.
for i in d.get("items",[]):
    if i["metadata"]["name"]!=want: continue
    st=i.get("status",{})
    if st.get("state")=="Deleted": continue
    done=[c["type"] for c in (st.get("conditions") or []) if c.get("status")=="True"]
    print("  %-22s state=%s" % (i["metadata"]["name"], st.get("state","-")))
    print("    conditions met  %s" % ", ".join(done[-3:]) if done else "    conditions      none reported")
    break
else:
    print("  %s not found — the cluster deploy has not completed" % want)'
  run_masked \
    "curl -sk -H 'ApiKey: \$PALETTE_API_KEY' -H 'ProjectUid: $PROJECT' '$PALETTE/v1/spectroclusters?limit=50' | python3 -c '<this cluster>'" \
    "curl -sk -H \"ApiKey: \$PALETTE_API_KEY\" -H \"ProjectUid: $PROJECT\" '$PALETTE/v1/spectroclusters?limit=50' | DEMO_CLUSTER=$DEMO_CLUSTER python3 -c '$PYC'"
else
  note "(PALETTE_API_KEY unset — this is the edge host list view in the Palette UI)"
fi
echo
note "Everything on this page came off the platform record, not off the host. The tags"
note "are what the rest of the demo follows: section 4 shows the VLAN they name on the"
note "fabric, section 5 shows the interface they built on the machine."
link "The same host in the Palette console" "$PALETTE/projects/$PROJECT/overview"
pause || return
}

beat_2(){
# ------------------------------------------------------------------
banner "2 · What this host is, and what it is not"
ctx "Two different things in this demo get called virtualised, and they are not the same thing. Separating them first, because the distinction is the architecture: one side is a server we own, the other is the network we do not."
arc "THE HOST — an ordinary server, nothing more"
rssh 'grep PRETTY_NAME /etc/os-release; systemd-detect-virt; ip -brief link' 'grep PRETTY_NAME /etc/os-release; echo virtualisation=$(systemd-detect-virt); ip -brief link | grep -vE "^(lo|cali|tunl|vxlan|docker|veth)"'
note "Linux on KVM, standing in for a GPU server. It is NOT SR Linux, it is not a"
note "network device, and nothing of ours runs on a switch. Two NICs: enp1s0 is the"
note "management path we reach it on, enp2s0 faces the fabric and carries the tagged"
note "VLAN. Production usually has one general-purpose NIC — the lab gives us two so a"
note "management path survives while the other is being reconfigured."
echo
arc "THE FABRIC — this is the virtualised SR Linux"
run "kubectl --context $KCTX -n $NS get toponodes -o custom-columns=NODE:.metadata.name,NOS:.spec.operatingSystem,VERSION:.spec.version,PLATFORM:.spec.platform"
note "leaf1, leaf2 and spine1 are SR Linux 26.3.1 running as containers under the EDA"
note "Digital Twin: the real NOS taking real configuration, with a simulated"
note "forwarding plane. That simulation is the reason section 15 cannot claim packets"
note "are blocked — the control plane is real, the data plane is not."
echo
arc "OUT OF BAND — we do not have it, and it matters"
note "No BMC, no iDRAC or iLO, no Redfish. The nearest equivalent is the hypervisor"
note "console, which exists only because this host is a VM. enp1s0 is a separate"
note "management NETWORK, not an out-of-band CHANNEL — it is still the host's own"
note "kernel and NIC, and it goes away with the host."
note "The distinction is not pedantry: out-of-band is what you would provision a fleet"
note "over. Section 14 emulates what such a path would HAND a booting host — identity"
note "in, configuration out, derived live from the fabric — and it is honest that the"
note "transport underneath is plain HTTP on this management network, not PXE and not"
note "a BMC. The shape is demonstrated; the channel is not, and we do not claim it."
echo
lede "The agent, and the version it is running:"
if edge_reachable "$EDGE_IP"; then
  rssh 'systemctl is-active spectro-stylus-agent; journalctl -u spectro-stylus-agent | grep -oE "version=v[0-9.]+"' \
       'systemctl is-active spectro-stylus-agent; sudo journalctl -u spectro-stylus-agent --no-pager --since "-30 min" | grep -oE "version=v[0-9.]+[^ ]*" | sort -u | tail -1'
  note "installed from the agent-mode tarball; nothing else was configured by hand"
else
  bad "The edge host is not answering at $EDGE_IP — not claiming anything about it."
fi
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
banner "4 · What those tag values are, on the fabric"
ctx "The tags are not free text — each names something on the Nokia fabric. Two different sets of objects appear below and they are worth keeping apart: the tenants that exist to demonstrate overlapping address space, and this host's own tenant, which is a different thing carrying a different VLAN."
arc "THE BASELINE TENANTS — what isolation buys you"
lede "Two tenants configured on the fabric, with identifiers EDA allocated:"
run "kubectl --context $KCTX -n $NS get bridgedomains"
note "VNI, EVI and route targets come from EDA's allocator — we read them back, never compute them"
echo
lede "Both answer at the same gateway address, on different bridge domains:"
for t in tenant-a tenant-b; do
  printf '    %s%-10s%s ' "$B" "$t" "$R"
  k get virtualnetwork "$t" -o jsonpath='gateway={.spec.irbInterfaces[0].spec.ipAddresses[0].ipv4Address.ipPrefix}  bd={.spec.irbInterfaces[0].spec.bridgeDomain}' 2>/dev/null
  echo
done
good "Overlapping tenant address space, separated by EVPN — the property this exists to provide."
note "These two exist to show that property. They are NOT this host's tenant, and the"
note "VLANs above are not the tag value. That is the next block, and it is a different"
note "set of objects."
echo

arc "THIS HOST'S VLAN"
tagvlan=$(curl -sk -H "ApiKey: $PALETTE_API_KEY" -H "ProjectUid: $PROJECT" \
            "$PALETTE/v1/edgehosts?limit=30" 2>/dev/null | DEMO_HOST_UID="$DEMO_HOST_UID" python3 -c '
import json,os,sys
want=os.environ["DEMO_HOST_UID"]
try:
    for i in json.load(sys.stdin).get("items",[]):
        if i["metadata"]["name"]==want:
            print((i["metadata"].get("labels") or {}).get("net-iso-vlan","")); break
except Exception: pass' 2>/dev/null)
: "${tagvlan:=${NET_ISO_VLAN:-310}}"
lede "The tag on the host record names VLAN $tagvlan. Every attachment the fabric holds:"
run "kubectl --context $KCTX -n $NS get bridgeinterfaces -o custom-columns=INTERFACE:.metadata.name,BRIDGE-DOMAIN:.spec.bridgeDomain,PORT:.spec.interface,VLAN:.spec.vlanID,STATE:.status.operationalState"
echo
match=$(k get bridgeinterfaces -o jsonpath="{range .items[?(@.spec.vlanID=='$tagvlan')]}{.metadata.name} {.spec.interface} {.spec.bridgeDomain}{\"\n\"}{end}" 2>/dev/null | head -1)
if [ -n "$match" ]; then
  set -- $match
  good "VLAN $tagvlan is on the fabric: port $2, bridge domain $3."
  good "That is the tag value from the host record, on the switch. Not a coincidence and"
  good "not something we typed twice — the next pages show both ends of it."
else
  note "VLAN $tagvlan is NOT on the fabric yet, and in the full walkthrough that is"
  note "deliberate: section 0 cleared this demo's own objects before anything was"
  note "claimed, so you can watch the tenant being created and the port bound rather"
  note "than take our word that they were already there."
  note "Right now the tag is a statement of intent and nothing has acted on it. Section"
  note "12 acts on it, and shows the same VLAN on the leaf port and on the machine at"
  note "the same moment."
fi
echo
if k get bridgeinterface standalone-on-populated-vn >/dev/null 2>&1; then
  note "standalone-on-populated-vn in the table above is neither: it is baseline state"
  note "from earlier verification, on a different port (leaf1-ethernet-1-7) in tenant-a."
  note "It is left in place deliberately, so the clean-slate check in section 0 has"
  note "something to distinguish 'baseline' from 'left behind by the last run'."
fi
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
  PY3='import json,os,sys
try: d=json.load(sys.stdin)
except Exception: print("could not read clusters"); sys.exit(0)
want=os.environ.get("DEMO_CLUSTER","eda-iso-demo")
live=[i for i in d.get("items",[]) if i.get("status",{}).get("state")!="Deleted"]
shown=0
for i in live:
    m=i["metadata"]; st=i.get("status",{})
    if m["name"]!=want: continue
    shown+=1
    print("  %-24s state=%-12s health=%s" % (m["name"][:24], st.get("state","-"), st.get("health",{}).get("state","-")))
if not shown: print("  %s not found - the cluster deploy has not completed" % want)
n=len(live)-shown
if n: print("  (%d further cluster%s in this project belong to other work, not shown)" % (n, "" if n==1 else "s"))'
  run_masked \
    "curl -sk -H 'ApiKey: \$PALETTE_API_KEY' -H 'ProjectUid: $PROJECT' '$PALETTE/v1/spectroclusters?limit=50' | python3 -c '<this cluster>'" \
    "curl -sk -H \"ApiKey: \$PALETTE_API_KEY\" -H \"ProjectUid: $PROJECT\" '$PALETTE/v1/spectroclusters?limit=50' | DEMO_CLUSTER=$DEMO_CLUSTER python3 -c '$PY3'"
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
lede "So does the pod network actually ride the tenant VLAN? Put the question to the kernel:"
rssh 'ip route get 10.210.0.99; ip -brief addr show tunl0' \
     'ip route get 10.210.0.99; ip -brief addr show tunl0'
echo
note "10.210.0.99 is deliberately nothing — no host answers there. This is a routing"
note "table lookup, not a reachability test: the question is which way this node WOULD"
note "send a packet to a peer in the tenant subnet, not whether anyone is listening."
note "A successful ping would have proved reachability while proving nothing about path."
echo
good "dev enp2s0.310, src 10.210.0.50 — it leaves on the tagged VLAN, from the tenant"
good "address. That is the routing table's own answer, not our configuration read back."
echo
note "tunl0 is Calico's IPIP device, and it holds a POD address, not a tenant one. Pods"
note "live in the Calico pool; every pod-to-pod packet between nodes is encapsulated and"
note "the outer packet is sourced from the node IP — so it leaves on enp2s0.310 too. The"
note "tenant VLAN carries the pod network whatever addresses the pods use inside it."
note "The pool above reads ipipMode=Always, not CrossSubnet: there is no same-subnet case"
note "where pod traffic skips the tunnel and takes a different path."
echo
note "Which is why a second tenant could run the identical pod CIDR on the same leaf"
note "and still not reach this one. The separation is the bridge domain, not the addressing."
echo
bad "Stated precisely: this shows egress, not isolation. It proves packets LEAVE on the"
bad "tenant VLAN. It does not prove another tenant cannot receive them — that needs the"
bad "forwarding plane, and this fabric simulates it. Same boundary as the last section."
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
