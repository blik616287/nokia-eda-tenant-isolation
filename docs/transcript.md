# Transcript — a complete run

This is the whole of `make demo`, recorded from a real run against the live fabric. Nothing here
is reconstructed: it is the terminal output, with the edge registration token masked.

| | |
|---|---|
| Recorded | 2026-08-27 |
| Result | exit 0, 19 pages |
| EDA transactions | 6 (a cached run would move this by zero) |
| Fabric | EDA 26.4.3 Digital Twin, SR Linux 26.3.1, two leaves and a spine |
| Host | Ubuntu 24.04 on KVM, edge agent v4.9.39-rc.4, k3s v1.35.3+k3s1 |
| Started from | `EDGE_IP` unset, so the walkthrough resolved the host itself |

Identifiers change every run — EDA allocates VNI, EVI and route targets, and libvirt hands the
host a different management address on each reboot. If they were identical run to run, it would
mean we were computing them.

The pages that take a minute are 4 and 8: they are driving the fabric, not describing it.

---

## Title card

```
     edge host is at 192.168.122.206, not 192.168.122.3 — using the address that answers
[H[2J[3J
   ███████ ██████   ███████  ██████ ████████ ██████   ██████
   ██      ██   ██  ██      ██         ██    ██   ██ ██    ██
   ███████ ██████   █████   ██         ██    ██████  ██    ██   ×  N O K I A   E D A
        ██ ██       ██      ██         ██    ██   ██ ██    ██
   ███████ ██       ███████  ██████    ██    ██   ██  ██████

   Fabric-level tenant isolation for Palette-managed GPU hosts
        2026-08-28  ·  EDA 26.4.3 Digital Twin  ·  SR Linux 26.3.1  ·  stylus v4.9.39-rc.4

    ▸ Integration companion — architecture, findings, and the ask
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/docs/companion.md
     section 0  ·  page 1 of 19
```

## 0 · Clean-slate check

```
╔══════════════════════════════════════════════════════════════╗
║  0 · Clean-slate check                                       ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Leftover state can make a fabric look healthy while an orphaned object silently fails every
     EDA transaction. Nothing below is claimed until the starting state is verified.
     ✓ EDA fabric reachable
     ✓ baseline tenants present — tenant-a, tenant-b
     ✓ no leftover objects from previous runs
     ✓ no orphaned bridge interfaces
     ✓ recent EDA transactions healthy
     ✓ clean slate — nothing to clear
     ✓ edge host 192.168.122.206 reachable, tenant VLAN up
     section 1  ·  page 2 of 19
```

## 1 · The edge host, in Palette

```
╔══════════════════════════════════════════════════════════════╗
║  1 · The edge host, in Palette                               ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Everything starts from the platform's own inventory. This is an ordinary registered edge
     host — the only thing special about it is the tags it carries, and those are visible
     right here on the record.
  The host this demo runs on, as Palette has it registered:

  $ curl -sk -H 'ApiKey: $PALETTE_API_KEY' -H 'ProjectUid: 6a29d0ddf00d553f0c969dca' 'https://palette.isc-spectro-dev.click/v1/edgehosts?limit=30' | python3 -c '<this host>'
      lab-gpu-01
        health        healthy — system is healthy
        state         in-use
        agent         v4.9.39-rc.4
        cluster       eda-iso-demo
        isolation     provider=eda  interface=enp2s0  vlan=310
                      subnet=10.210.0.50/24
                      5 net-iso labels on the host record
      (5 further hosts in this project belong to other work, not shown)

  And the cluster that host is running:

  $ curl -sk -H 'ApiKey: $PALETTE_API_KEY' -H 'ProjectUid: 6a29d0ddf00d553f0c969dca' 'https://palette.isc-spectro-dev.click/v1/spectroclusters?limit=50' | python3 -c '<this cluster>'
      eda-iso-demo           state=Running
        conditions met  ControlPlaneNodeAdditionDone, WorkerNodeAdditionDone, AddOnDeploymentDone

     Everything on this page came off the platform record, not off the host. The tags
     are what the rest of the demo follows: section 4 shows the VLAN they name on the
     fabric, section 5 shows the interface they built on the machine.
    ▸ The same host in the Palette console
      https://palette.isc-spectro-dev.click/projects/6a29d0ddf00d553f0c969dca/overview
     section 2  ·  page 3 of 19
```

## 2 · What this host is, and what it is not

```
╔══════════════════════════════════════════════════════════════╗
║  2 · What this host is, and what it is not                   ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Two different things in this demo get called virtualised, and they are not the same thing.
     Separating them first, because the distinction is the architecture: one side is a server we
     own, the other is the network we do not.

  ── THE HOST — an ordinary server, nothing more ──

  $ ssh lab-gpu-01 'grep PRETTY_NAME /etc/os-release; systemd-detect-virt; ip -brief link'
    PRETTY_NAME="Ubuntu 24.04.4 LTS"
    virtualisation=kvm
    enp1s0           UP             52:54:00:04:f3:de <BROADCAST,MULTICAST,UP,LOWER_UP> 
    enp2s0           UP             52:54:00:3f:b1:7a <BROADCAST,MULTICAST,UP,LOWER_UP> 
    enp2s0.310@enp2s0 UP             52:54:00:3f:b1:7a <BROADCAST,MULTICAST,UP,LOWER_UP> 
     Linux on KVM, standing in for a GPU server. It is NOT SR Linux, it is not a
     network device, and nothing of ours runs on a switch. Two NICs: enp1s0 is the
     management path we reach it on, enp2s0 faces the fabric and carries the tagged
     VLAN. Production usually has one general-purpose NIC — the lab gives us two so a
     management path survives while the other is being reconfigured.


  ── THE FABRIC — this is the virtualised SR Linux ──

  $ kubectl --context kind-eda-demo -n eda get toponodes -o custom-columns=NODE:.metadata.name,NOS:.spec.operatingSystem,VERSION:.spec.version,PLATFORM:.spec.platform
    NODE     NOS   VERSION   PLATFORM
    leaf1    srl   26.3.1    7220 IXR-D3L
    leaf2    srl   26.3.1    7220 IXR-D3L
    spine1   srl   26.3.1    7220 IXR-D5
     leaf1, leaf2 and spine1 are SR Linux 26.3.1 running as containers under the EDA
     Digital Twin: the real NOS taking real configuration, with a simulated
     forwarding plane. That simulation is the reason section 15 cannot claim packets
     are blocked — the control plane is real, the data plane is not.


  ── OUT OF BAND — we do not have it, and it matters ──
     No BMC, no iDRAC or iLO, no Redfish. The nearest equivalent is the hypervisor
     console, which exists only because this host is a VM. enp1s0 is a separate
     management NETWORK, not an out-of-band CHANNEL — it is still the host's own
     kernel and NIC, and it goes away with the host.
     The distinction is not pedantry: out-of-band is what you would provision a fleet
     over. Section 14 emulates what such a path would HAND a booting host — identity
     in, configuration out, derived live from the fabric — and it is honest that the
     transport underneath is plain HTTP on this management network, not PXE and not
     a BMC. The shape is demonstrated; the channel is not, and we do not claim it.

  The agent, and the version it is running:

  $ ssh lab-gpu-01 'systemctl is-active spectro-stylus-agent; journalctl -u spectro-stylus-agent | grep -oE "version=v[0-9.]+"'
    active
    version=v4.9.39-rc.4
     installed from the agent-mode tarball; nothing else was configured by hand
     section 3  ·  page 4 of 19
```

## 3 · The tags, and where they came from

```
╔══════════════════════════════════════════════════════════════╗
║  3 · The tags, and where they came from                      ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     The tags are not applied after the fact. They are written into the host's user-data before
     it ever registers, because the agent snapshots them at registration and never re-reads them.
  The user-data that was placed on the host before first boot:

  $ sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@192.168.122.206 'sudo sed -n "/^stylus:/,/^install:/p" /var/lib/spectro/userdata | head -20'
    stylus:
      skipStylusUpgrade: true
      site:
        edgeHostToken: <redacted for this walkthrough>
        paletteEndpoint: palette.isc-spectro-dev.click
        name: lab-gpu-01
        projectName: Default
        insecureSkipVerify: true
        tags:
          net-iso-provider: eda
          net-iso-interface: enp2s0
          net-iso-vlan: "310"
          net-iso-subnet-ipv4: 10.210.0.50
          net-iso-subnet-prefix-length: "24"
    install:

  And the same values, now as tags on the host in Palette:

  $ curl -sk -H 'ApiKey: $PALETTE_API_KEY' -H 'ProjectUid: 6a29d0ddf00d553f0c969dca' 'https://palette.isc-spectro-dev.click/v1/edgehosts/lab-gpu-01' | python3 -c '<print net-iso tags>'
      host: lab-gpu-01  health: healthy
        net-iso-interface = enp2s0
        net-iso-provider = eda
        net-iso-subnet-ipv4 = 10.210.0.50
        net-iso-subnet-prefix-length = 24
        net-iso-vlan = 310
     ✓ Same values, round-tripped: user-data on the host, tags in the platform.
     section 4  ·  page 5 of 19
```

## 4 · Those tag values are VLANs EDA configured

```
╔══════════════════════════════════════════════════════════════╗
║  4 · Those tag values are VLANs EDA configured               ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     The tags are not free text. The VLAN in them has to exist on the Nokia fabric, in a tenant,
     on the port this machine is cabled to. Rather than describe that, this page asks EDA for it
     and shows the result.
  The host record names VLAN 310. Asking EDA for that tenant now:
    zz_act5_driver_test.go:143: UNIT READY origin=Managed bd=nokia-demo-bd router=nokia-demo-router vni=204 evi=104 rt=target:1:104
    zz_act5_driver_test.go:168: BOUND host=lab-gpu-01 node=lab-gpu-01 leaf=leaf1 iface=leaf1-ethernet-1-9 bi=nokia-demo-pool-leaf1-ethernet-1-9 vlan=310 state=Up
    zz_act5_driver_test.go:176: FABRIC CONFIRMS subifs=1 down=0 nodes=1 state=Up
    zz_act5_driver_test.go:178: PERSISTED unit=eda/nokia-demo bd=nokia-demo-bd
     Nothing there is precomputed. We name a tenant and a port; EDA allocates the VNI,
     the EVI and the route targets and reports them back. origin=Managed means we
     created the tenant; Adopted means one already existed and we took it over.

  The tenant that just appeared:

  $ kubectl --context kind-eda-demo -n eda get bridgedomain nokia-demo-bd -o custom-columns=TENANT:.metadata.name,VNI:.status.vni,EVI:.status.evi,ROUTE-TARGET:.status.importTarget,SUBIFS:.status.numSubinterfaces,STATE:.status.operationalState
    TENANT          VNI   EVI   ROUTE-TARGET   SUBIFS   STATE
    nokia-demo-bd   204   104   target:1:104   1        Up

  And the port it now holds:

  $ kubectl --context kind-eda-demo -n eda get bridgeinterface nokia-demo-pool-leaf1-ethernet-1-9 -o custom-columns=ATTACHMENT:.metadata.name,PORT:.spec.interface,VLAN:.spec.vlanID,TENANT:.spec.bridgeDomain,STATE:.status.operationalState
    ATTACHMENT                           PORT                 VLAN   TENANT          STATE
    nokia-demo-pool-leaf1-ethernet-1-9   leaf1-ethernet-1-9   310    nokia-demo-bd   Up

     ✓ VLAN 310 on leaf1-ethernet-1-9, in nokia-demo-bd — the value on the host
     ✓ record, now on the switch. Section 8 comes back to this fabric and to what
     ✓ belonging to a tenant actually buys you.
     section 5  ·  page 6 of 19
```

## 5 · The designated interface, on the VM

```
╔══════════════════════════════════════════════════════════════╗
║  5 · The designated interface, on the VM                     ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     This is the host half. Nobody logged in and configured it; the agent read the tags and
     built it during cloud-init, before Kubernetes started.
  The interface named by net-iso-interface, carrying the tagged VLAN:

  $ sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@192.168.122.206 'ip -d link show enp2s0.310 | head -3'
    4: enp2s0.310@enp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000
        link/ether 52:54:00:3f:b1:7a brd ff:ff:ff:ff:ff:ff promiscuity 0  allmulti 0 minmtu 0 maxmtu 65535 
        vlan protocol 802.1Q id 310 <REORDER_HDR> addrgenmode none numtxqueues 1 numrxqueues 1 gso_max_size 65536 gso_max_segs 65535 tso_max_size 65536 tso_max_segs 65535 gro_max_size 65536 

  $ ssh lab-gpu-01 'ip -brief addr'
    enp1s0           UP             192.168.122.206/24 metric 100 fe80::5054:ff:fe04:f3de/64 
    enp2s0           UP             
    enp2s0.310@enp2s0 UP             10.210.0.50/24 10.210.0.100/32 

     enp1s0 is the management path. enp2s0 has no address of its own.
     ✓ 802.1Q VLAN 310 at 10.210.0.50/24 — exactly the tag values from section 3.

     Where that address came from is worth being precise about, because it is not
     obvious: nothing on the fabric issued it. There is no DHCP here and no IPAM
     exchange with EDA. The agent read net-iso-subnet-ipv4 off its own tags and
     configured the interface itself. The address IS the tag.

     ✓ And the fabric agrees: leaf1-ethernet-1-9 is in nokia-demo-bd. Both halves are in place.
     Worth one sentence on why we bothered checking, because it is the whole
     argument for how this is built: everything ABOVE this line would look exactly
     the same if the fabric half were missing. The agent takes the address from its
     own tags — no DHCP, no exchange with EDA — so the interface comes up, the node
     gets its address and a single-node cluster runs perfectly well while attached
     to nothing. A host that is not isolated is indistinguishable from one that is,
     from the host. That is why readiness is gated on the fabric's own answer, and
     why section 10 refuses to write anything at all rather than write half of it.
     section 6  ·  page 7 of 19
```

## 6 · The cluster on that host

```
╔══════════════════════════════════════════════════════════════╗
║  6 · The cluster on that host                                ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     The isolated interface is not decoration. It is the address Kubernetes itself came up on,
     which is only possible because it existed before the cluster bootstrapped.
  The edge cluster, as Palette sees it:

  $ curl -sk -H 'ApiKey: $PALETTE_API_KEY' -H 'ProjectUid: 6a29d0ddf00d553f0c969dca' 'https://palette.isc-spectro-dev.click/v1/spectroclusters?limit=50' | python3 -c '<this cluster>'
      eda-iso-demo             state=Running      health=-
      (2 further clusters in this project belong to other work, not shown)
  And the node itself:

  $ sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@192.168.122.206 'sudo k3s kubectl get nodes -o wide'
    NAME         STATUS   ROLES                AGE     VERSION        INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
    lab-gpu-01   Ready    control-plane,etcd   4h18m   v1.35.3+k3s1   10.210.0.50   10.210.0.50   Ubuntu 24.04.4 LTS   6.8.0-137-generic   containerd://2.2.2-k3s1
     ✓ The node's InternalIP is 10.210.0.50 — the isolated address, not the management one.
     section 7  ·  page 8 of 19
```

## 7 · Where the cluster's traffic actually goes

```
╔══════════════════════════════════════════════════════════════╗
║  7 · Where the cluster's traffic actually goes               ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     This is the question a network engineer asks, so it is worth being exact. Pod and Service
     addresses are the cluster's own — they are not tenant addresses, and they are not the
     isolated subnet. What makes them isolated is the interface every packet leaves on.
  The cluster's address ranges, as they actually are:

  $ sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@192.168.122.206 'sudo k3s kubectl get ippools.crd.projectcalico.org -o custom-columns=POOL:.metadata.name,CIDR:.spec.cidr,IPIP:.spec.ipipMode --no-headers | head -1'
    default-ipv4-ippool   172.16.0.0/16         Always

  $ sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@192.168.122.206 'sudo k3s kubectl get svc -A --no-headers | awk "{print \$4}" | grep -v none | sort -u | head -3'
    192.169.0.1
    192.169.0.10
    192.169.183.244
     pods come from Calico's pool, Services from the service CIDR. Neither is 10.210.0.0/24.

  Which is the point — look at what each pod actually holds:

  $ sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@192.168.122.206 'sudo k3s kubectl get pods -A -o wide --no-headers | awk "\$7 ~ /[0-9]/ {printf \"  %-46s %s\\n\", \$2, \$7}" | sort -k2 | head -9'
      calico-node-9tjpp                              10.210.0.50
      coredns-c4dbffb5f-nzbgj                        172.16.45.66
      cert-manager-74d7c568c-khd5b                   172.16.45.72
      metrics-server-786d997795-8gv8m                172.16.45.71
      metrics-server-85dbd6f44d-xmdcd                172.16.45.76
      palette-webhook-5cd4b75c6d-cqnw2               172.16.45.75
      cert-manager-webhook-7bdb866f7c-qxzjh          172.16.45.74
      cert-manager-cainjector-b8b4645cf-qdsd7        172.16.45.73
      calico-kube-controllers-5c7cf4bc74-swtt5       172.16.45.67
     host-network pods (calico-node, kube-vip) carry 10.210.0.50 — the isolated address.
     pod-network pods carry Calico pool addresses.

  So does the pod network actually ride the tenant VLAN? Put the question to the kernel:

  $ ssh lab-gpu-01 'ip route get 10.210.0.99; ip -brief addr show tunl0'
    10.210.0.99 dev enp2s0.310 src 10.210.0.50 uid 1000 
        cache 
    tunl0@NONE       UNKNOWN        172.16.45.64/32 

     10.210.0.99 is deliberately nothing — no host answers there. This is a routing
     table lookup, not a reachability test: the question is which way this node WOULD
     send a packet to a peer in the tenant subnet, not whether anyone is listening.
     A successful ping would have proved reachability while proving nothing about path.

     ✓ dev enp2s0.310, src 10.210.0.50 — it leaves on the tagged VLAN, from the tenant
     ✓ address. That is the routing table's own answer, not our configuration read back.

     tunl0 is Calico's IPIP device, and it holds a POD address, not a tenant one. Pods
     live in the Calico pool; every pod-to-pod packet between nodes is encapsulated and
     the outer packet is sourced from the node IP — so it leaves on enp2s0.310 too. The
     tenant VLAN carries the pod network whatever addresses the pods use inside it.
     The pool above reads ipipMode=Always, not CrossSubnet: there is no same-subnet case
     where pod traffic skips the tunnel and takes a different path.

     Which is why a second tenant could run the identical pod CIDR on the same leaf
     and still not reach this one. The separation is the bridge domain, not the addressing.

     ✗ Stated precisely: this shows egress, not isolation. It proves packets LEAVE on the
     ✗ tenant VLAN. It does not prove another tenant cannot receive them — that needs the
     ✗ forwarding plane, and this fabric simulates it. Same boundary as the last section.

  ── WHERE WE ARE GOING ──
     section 8  ·  page 9 of 19
```

## 8 · The fabric, and what "isolated" means here

```
╔══════════════════════════════════════════════════════════════╗
║  8 · The fabric, and what "isolated" means here              ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Your node is in nokia-demo. To show what that membership is actually worth, this page
     creates a second tenant on the same three switches and gives it the IDENTICAL gateway
     address — then shows what keeps them apart.
    +================================+            +================================+
    | EDA FABRIC - Nokia SR Linux    |            | PALETTE EDGE HOST              |
    | leaf1 / leaf2  7220 IXR-D3L    |  <======>  | lab-gpu-01                     |
    | spine1         7220 IXR-D5     |  VLAN 310  | enp2s0  ->  enp2s0.310         |
    | tenant bridge domains (EVPN)   |  <======>  | 10.210.0.50/24                 |
    +================================+            +================================+
      leaf1-ethernet-1-9 is the one port lab-gpu-01 is cabled to
  Creating a neighbour tenant at the same address as yours:
    virtualnetwork.services.eda.nokia.com/nokia-neighbour created

  Your tenant, and its new neighbour:

  $ kubectl --context kind-eda-demo -n eda get bridgedomains nokia-demo-bd nokia-neighbour-bd -o custom-columns=TENANT:.metadata.name,VNI:.status.vni,EVI:.status.evi,ROUTE-TARGET:.status.importTarget
    TENANT               VNI   EVI   ROUTE-TARGET
    nokia-demo-bd        204   104   target:1:104
    nokia-neighbour-bd   207   106   target:1:106

  And the address each one answers at:
    nokia-demo         gateway=10.210.0.1/24
    nokia-neighbour    gateway=10.210.0.1/24

     ✓ The same address, on the same fabric, in two different tenants.
     What separates them is the route target. Route targets decide which VRF imports
     whose routes, and these two do not import each other's — so neither network can
     learn the other's addresses at all. It is not a filter applied to traffic; the
     routes are never exchanged in the first place.
     Your node sits in nokia-demo. Nothing in nokia-neighbour can reach it and it can
     reach nothing there, even though both are using 10.210.0.1. That is the property
     this whole integration exists to provide, and it is why a customer's address plan
     stops being something anyone else has to be consulted about.

    ▸ EDA documentation
      https://docs.eda.dev/
    ▸ SR Linux documentation
      https://documentation.nokia.com/srlinux/
    ▸ RFC 7432 — BGP MPLS-Based Ethernet VPN
      https://www.rfc-editor.org/rfc/rfc7432
     section 9  ·  page 10 of 19
```

## 9 · A GPU host bound to its physical leaf port

```
╔══════════════════════════════════════════════════════════════╗
║  9 · A GPU host bound to its physical leaf port              ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     To put a server into a tenant, something has to know which switch port it is plugged into.
     There is no API for that question, and the reason is reasonable: EDA models the fabric, and
     a GPU server is not part of the fabric. What we did was read the cabling records backwards
     — the Day-0 topology already records that port X connects to host Y, so we searched it by
     host. It works. Nokia reviewed it and said the record does not belong there, and we agree.
     The replacement is at the bottom of this page.
     In plain terms: we needed a phone book from server to switch port, nobody keeps
     one, so we read the switch's own wiring list backwards. That works and it is the
     wrong place to look it up.
  Running the provider's reconcilers against the live fabric.
     This host's port is already in its tenant, from page 4. It has exactly one cabled
     port, so rather than bind it twice, here is the resolution that produced it and
     the fabric's own confirmation of the result.


  $ kubectl --context kind-eda-demo -n eda get topolinks -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    for l in i['spec'].get('links',[]):
        if l.get('type')=='edge' and (l.get('remote') or {}).get('node'):
            print(' ', l['remote']['node'], '->', l['local']['node'], l['local']['interfaceResource'])"
      lab-gpu-01 -> leaf1 leaf1-ethernet-1-9


  $ kubectl --context kind-eda-demo -n eda get bridgedomain nokia-demo-bd -o jsonpath='FABRIC CONFIRMS  subifs={.status.numSubinterfaces}  nodes={.status.numNodes}  state={.status.operationalState}{"\n"}'
    FABRIC CONFIRMS  subifs=1  nodes=1  state=Up

     Reading those three lines:

     UNIT READY       the tenant network exists. The VNI, EVI and route target on that
                      line were allocated by EDA and read back — none of them supplied
                      by us. Identical values run to run would mean we had computed them.
     BOUND            the host was resolved to the one leaf port it is cabled to, and
                      that port placed into the tenant: leaf1, ethernet-1-9, VLAN 310.
     FABRIC CONFIRMS  a DIFFERENT object — the bridge domain — reporting how many
                      sub-interfaces it now carries. One. That is the fabric agreeing
                      with the request, not the request being read back to itself.

     ✓ Only the third line is evidence.
     EDA accepts a BridgeInterface before the transaction that programs the switch has
     committed. An API success therefore proves the intent was recorded, not that the
     port was moved. Readiness is gated on the bridge domain's numSubinterfaces — a
     field the live CRDs and the documentation disagree about, and the CRDs win.

     On the resolution above: your review is that an edge TopoLink should describe the
     switch side only, and we accept that. The reverse-index is being replaced by the
     leaf port carried directly on the host record — RFC-0021 §4e. What is bound, and
     how the fabric confirms it, is unchanged either way.

    ▸ Integration companion — §4.3, host-to-port resolution
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/docs/companion.md#43-host-to-leaf-port-resolution-the-part-we-are-replacing
    ▸ RFC 8365 — Network Virtualization Overlay Solution Using EVPN
      https://www.rfc-editor.org/rfc/rfc8365
     section 10  ·  page 11 of 19
```

## 10 · Fail-closed behaviour

```
╔══════════════════════════════════════════════════════════════╗
║  10 · Fail-closed behaviour                                  ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     This is the failure that worries us most, and it is worth stating before the tests run.
     When network isolation does not happen, nothing visibly breaks. The server boots, joins its
     cluster and passes every health check — it simply is not isolated. No error, no alert,
     and the first person to find out is whoever should not have been able to reach it. So
     anything less than complete success has to be treated as failure.
     In plain terms: a lock that silently fails open. The tests below exist to prove
     we refuse to write anything at all rather than write half of it.
  These tests run offline — they pass with the fabric switched off.
    TestPortAttachmentReconcilerReconcile/Attached_only_once_every_binding_is_operational (0.00s)
    TestPortAttachmentReconcilerReconcile/two_hosts_claiming_one_port_fails_without_writing (0.00s)
    TestPortAttachmentReconcilerReconcile/host_with_no_fabric_node_fails_the_whole_request_and_writes_nothing (0.00s)
    TestPortAttachmentReconcilerReconcile/fabric_node_matching_no_topolink_is_unmapped (0.00s)
    TestPortAttachmentReconcilerConfigErrorBackoff/two_hosts_on_one_port (0.00s)
    TestVirtualNetworkReconcilerReconcile/bridge_domain_with_an_EVI_is_ready_even_at_operationalState_Unknown (0.00s)

     ✓ If any host in a pool cannot be resolved, the whole request fails and nothing is
     ✓ written to the fabric.
     Attaching only the resolvable subset would leave a pool partly isolated while
     reporting success. The tests assert the fabric is untouched, not just a return code.

     A multi-rail host must have every rail bound — one missed rail is a data-plane leak.
     Each of these behaviours was verified by removing it and confirming the suite fails.

    ▸ RFC-0014 — the pluggable network-isolation provider slot
      https://github.com/spectrocloud/mural/blob/main/rfc/0014-aviz-network-isolation.md
     section 11  ·  page 12 of 19
```

## 11 · The host side — the node IP, and the VIP contract

```
╔══════════════════════════════════════════════════════════════╗
║  11 · The host side — the node IP, and the VIP contract      ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     The switch side is only half of it. The server has to put its own traffic on the matching
     VLAN, and it has to do that before Kubernetes starts, because the node's address and the
     pod network both come up on that interface. Anything delivered after the cluster is healthy
     has missed its moment. That timing is the whole reason this is built into the platform
     rather than installed onto a running cluster.
     In plain terms: the machine has to be on the right network before it is a
     Kubernetes node at all, so this cannot be something you apply afterwards.
  Pages 3 and 5 showed the tags and the interface they built. This is what those
  values then determined, which is the part that cannot be applied afterwards.

  $ sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@192.168.122.206 'ip -d link show enp2s0.310 | head -3'
    4: enp2s0.310@enp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000
        link/ether 52:54:00:3f:b1:7a brd ff:ff:ff:ff:ff:ff promiscuity 0  allmulti 0 minmtu 0 maxmtu 65535 
        vlan protocol 802.1Q id 310 <REORDER_HDR> addrgenmode none numtxqueues 1 numrxqueues 1 gso_max_size 65536 gso_max_segs 65535 tso_max_size 65536 tso_max_segs 65535 gro_max_size 65536 

  $ sshpass -p demo ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR demo@192.168.122.206 'ip -brief addr show enp2s0.310'
    enp2s0.310@enp2s0 UP             10.210.0.50/24 10.210.0.100/32 
     802.1Q id 310 carrying 10.210.0.50/24 — exactly the tag values.

  The tags in Palette, which is the source of truth for them:

  $ curl -sk -H 'ApiKey: $PALETTE_API_KEY' -H 'ProjectUid: 6a29d0ddf00d553f0c969dca' 'https://palette.isc-spectro-dev.click/v1/edgehosts/lab-gpu-01' | python3 -c '<print net-iso labels>'
    host: lab-gpu-01  health: healthy
        net-iso-interface = enp2s0
        net-iso-provider = eda
        net-iso-subnet-ipv4 = 10.210.0.50
        net-iso-subnet-prefix-length = 24
        net-iso-vlan = 310
     These are snapshotted at first registration and never re-read, so they must exist
     before the host registers.

  And what Kubernetes then did with it:
    node-ip          = ['10.210.0.50']
    node-external-ip = ['10.210.0.50']
     ✓ Kubernetes came up on the isolated VLAN address, not the management IP.

     The agent also fail-closes when the control-plane VIP falls outside the tenant CIDR:
       invalid vip … is not in the CIDR 10.210.0.50/24
     — an independent signal that the tags were parsed, not merely accepted.

    ▸ Palette — project overview
      https://palette.isc-spectro-dev.click/projects/6a29d0ddf00d553f0c969dca/overview
    ▸ stylus #6354 — resolve the fabric NIC, build the VLAN sub-interface
      https://github.com/spectrocloud/stylus/pull/6354
    ▸ stylus #6394 — aviz-* renamed net-iso-* so a second provider shares the path
      https://github.com/spectrocloud/stylus/pull/6394
     section 12  ·  page 13 of 19
```

## 12 · Both halves, at the same time

```
╔══════════════════════════════════════════════════════════════╗
║  12 · Both halves, at the same time                          ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Both halves have now been shown on their own. Here they are together — the same VLAN on
     the switch port and on the server plugged into it. The two were put there by different
     systems that never speak to each other and never read each other's result. They agree
     because both were told the same thing.
     In plain terms: two people set the same channel on two radios from the same
     written order. If they ever disagreed nothing would break loudly — which is
     exactly the silent failure the previous page is about.

    FABRIC SIDE — placed by the provider
      leaf1-ethernet-1-9   vlan=310   bd=nokia-demo-bd   state=Up
      vni=204   evi=104   rt=target:1:104   subifs=1

    HOST SIDE — raised by the agent from Palette tags
      enp2s0.310@enp2s0 UP             10.210.0.50/24 10.210.0.100/32 

     ✓ Neither half reads the other.
     They agree because both derive from the same declared intent: the provider resolved
     the host to its leaf port through the Day-0 cabling intent, and the agent resolved the
     same host's tags into a local interface.

    ▸ Integration companion — §2, the two halves
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/docs/companion.md#2-what-we-are-integrating-and-why-it-is-not-trivial
    ▸ SR Linux learn — EVPN in practice
      https://learn.srlinux.dev/
     section 13  ·  page 14 of 19
```

## 13 · How Palette drives this — the ComputePool path

```
╔══════════════════════════════════════════════════════════════╗
║  13 · How Palette drives this — the ComputePool path         ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Everything so far was driven by calling our own code directly, which is not how anyone
     would actually use this. A user picks some hosts, groups them into a pool, and asks for
     that pool to be isolated. This page is that path: what a user declares, what it has to turn
     into, and precisely which link in the chain is not written yet.
     In plain terms: you have seen the engine run on a test bench. This is where it
     connects to the pedal, and one linkage is still missing.
  A user does not write EDA intent. They declare isolation on a ComputePool:
    apiVersion: spectrocloud.com/v1alpha1
    kind: ComputePool
    spec:
      networkIsolation:
        provider: EDA                        # the enum value added by mural#8944
        eda:
          edaVirtualNetwork: tenant-a        # which isolation unit
          subnet: gpu                        # which of its subnets -> access VLAN

  A provider-side watcher turns that into the two CRs you have already seen work:
       EDAVirtualNetwork        the isolation unit — one EDA VirtualNetwork per tenant
       EDAPortAttachmentRequest the per-pool binding — one BridgeInterface per leaf port

  That watcher is the one piece not yet written. The shipped Aviz analogue is the pattern:

  $ sed -n '/^\/\/ ComputePoolReconciler/,/^type ComputePoolReconciler/p'   "$FRISKET/internal/controller/aviz/computepool_controller.go" | head -6
    // ComputePoolReconciler watches hue/apis ComputePool resources filtered on
    // spec.networkIsolation.provider == Aviz and materializes exactly one
    // AvizGPUAllocationRequest owned by the pool.
    //
    // This is the ComputePool watcher (spec field) surface.
    type ComputePoolReconciler struct {
     the EDA equivalent mirrors it: watch ComputePool, filter provider == EDA,
     materialise one EDAPortAttachmentRequest owned by the pool. RFC-0021 item 13.

  So the state of the chain, honestly:
     ✓ EDAVirtualNetwork reconciler        written, tested, running here
     ✓ EDAPortAttachmentRequest reconciler written, tested, running here
     ✗ ComputePool -> CR watcher           NOT written — the CRs above were created directly
     ✗ provider: EDA on a ComputePool      NOT available — mural#8944 is open, on hold

     Nothing shown in sections 1-5 depends on those two. They are what turns a working
     integration into something a user can reach from the product.

    ▸ #8944 — the enum, CEL fix and EDANetworkIsolation type
      https://github.com/spectrocloud/mural/pull/8944
    ▸ #8946 — the attachment reconciler
      https://github.com/spectrocloud/mural/pull/8946
     section 14  ·  page 15 of 19
```

## 14 · Who writes the host's configuration, at fleet scale

```
╔══════════════════════════════════════════════════════════════╗
║  14 · Who writes the host's configuration, at fleet scale    ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Everything so far assumed the server already knew its own isolation settings. On this
     machine, someone put that file there by hand before it ever registered. That is honest for
     one server and impossible for a thousand — and it is also circular, because you cannot
     configure a machine's main network connection by talking to it over that same connection.
     This page is the way out of the circle.
     In plain terms: the machine has to be told which network it belongs to before it
     can be reached on that network. Something else has to answer that, at boot.
  Everything a booting host presents about itself — one value:

  $ echo 52:54:00:26:9a:5e
    52:54:00:26:9a:5e
     In production this is not even a lookup. The leaf's DHCP relay inserts Option 82
     circuit-id — the port the request arrived on — so the fabric names the port and
     nothing has to resolve the host at all. The Digital Twin has no forwarding plane,
     so there is no relay here; we key on MAC from inventory. The derivation is the same.

  What it is served, derived live from the fabric:

  $ ./scripts/provision-endpoint.py --once 52:54:00:26:9a:5e --explain
      identity      mac 52:54:00:26:9a:5e  ->  lab-gpu-01          (inventory; production: DHCP relay circuit-id)
      assignment    lab-gpu-01  ->  pool gpu-pool-a  ->  tenant nokia-demo   (Palette; RFC-0021 item 13)
      cabling       lab-gpu-01  ->  leaf1 leaf1-ethernet-1-9   (EDA TopoLink; RFC-0021 4e replaces this read)
      addressing    tenant nokia-demo  ->  gateway 10.210.0.1/24   (EDA IRB, read live)
      vlan          310   (from the fabric)
      host address  10.210.0.50/24   (reserved in inventory; IPAM owns nothing yet)
                    verified inside the tenant subnet -- fail closed if it is not
     Nothing per-host is authored. Two of those lines are ours to change and we have
     said so: the cabling read becomes the leaf port on the host record (RFC-0021 §4e),
     and pool-to-tenant is what the ComputePool watcher will own (RFC-0021 item 13).

  Against the values actually on the running host:
      net-iso-provider: eda
      net-iso-interface: enp2s0
      net-iso-vlan: "310"
      net-iso-subnet-ipv4: 10.210.0.50
      net-iso-subnet-prefix-length: "24"
     ✓ Identical. Derived from the fabric, not copied from the host.

  A service returning the right answer could be reciting it. Ask for a different tenant:

  $ ./scripts/provision-endpoint.py --once 52:54:00:26:9a:5e --tenant tenant-a
    LookupError: reserved address 10.210.0.50 is not in the tenant subnet 10.200.0.0/24 -- fail closed rather than bring a host up on the wrong network
     ✓ Fail closed. tenant-a's subnet is read live from its IRB, the reserved address is
     ✓ not inside it, and no configuration is served at all.

     ✓ CLOSED — per-host configuration is no longer authored anywhere. Every machine boots
     ✓ the same image and is told what it is.
     ✗ NOT CLOSED — the transport. A production host gets this over PXE/iPXE or an
     ✗ out-of-band installer; this is plain HTTP on the management network.
     ✗ NOT CLOSED — IPAM. The tenant subnet is the fabric's; which address inside it belongs
     ✗ to a host is a decision nothing owns yet, so it is carried as a reservation.

     DPU addressing arrives over DHCP and removes this circularity rather than routing
     around it. It is the better answer and it is yours — companion §8 for why we treat
     it as an optimisation rather than a prerequisite.

    ▸ Integration companion — §5.1, the bootstrap dependency
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/docs/companion.md#51-what-we-configure-and-what-we-deliberately-do-not
    ▸ The same ground in full — make demo-bootstrap
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/scripts/demo-bootstrap.sh
     section 15  ·  page 16 of 19
```

## 15 · What is proven, and what is not

```
╔══════════════════════════════════════════════════════════════╗
║  15 · What is proven, and what is not                        ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Everything up to here has been a claim. This is the accounting, including a caution about
     the evidence itself: Go replays a cached test result exactly, its timing included, so a
     green result on screen does not prove anything ran just now. The fabric's own transaction
     counter does, because nothing on this side can fake it.
     In plain terms: do not trust the test output, trust the count the switches keep.
     Zero would mean this whole session touched nothing, whatever the screen said.
  Transactions driven through EDA's engine during this session:
     EDA transactions: 3   (zero would mean nothing actually ran)

  $ kubectl --context kind-eda-demo -n eda-system get transactionresults --no-headers | tail -4
    transaction-000000592   OK       18m           
    transaction-000000593   OK       87s           
    transaction-000000594   OK       82s           
    transaction-000000595   OK       58s           

     ✓ PROVEN — EVPN tenancy with overlapping address space; host-to-leaf-port resolution
     ✓ and attachment; fail-closed behaviour; host VLAN raised from tags; Kubernetes
     ✓ running on the isolated address.

     ✗ NOT PROVEN — forwarding-plane isolation.
     Demonstrating that traffic genuinely cannot cross between tenants needs real
     endpoints, which needs SIMULATE=false and a licence. That is a licensing question
     rather than a technical blocker, and it is the first item on our ask.

     ✗ NOT PROVEN — multi-rail hosts and pool scaling on real hardware.
     Modelled and tested in the reconciler, but not exercised against a DGX-class host
     with several fabric-facing NICs, nor against a fabric with thousands of edge links.

    ▸ Integration companion — §6, the full proven / not-proven table
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/docs/companion.md#6-what-is-proven-and-what-is-not
     section 16  ·  page 17 of 19
```

## 16 · Where this stands

```
╔══════════════════════════════════════════════════════════════╗
║  16 · Where this stands                                      ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Nothing here was staged for today. Everything shown runs on code that is either already
     merged or open in review, and this page says which is which, what is still unwritten, and
     whose desk each open item sits on.
     In plain terms: nothing you were shown depends on unmerged work to be TRUE.
     It depends on unmerged work to SHIP, and those are different problems.

  ── THE STYLUS SIDE — merged ──
     #6354  resolve the isolated fabric NIC by name, build the VLAN sub-interface
     #6394  rename aviz-* tags to net-iso-*, so a second provider can share the path
     ✓ #6394 is the change that makes an EDA provider possible without forking the agent.

  ── THE PALETTE SIDE — in review ──
         #8944 [OPEN]          hue-apis: EDA provider + CEL admission fix
         #9124 [OPEN · DRAFT]  hue: gate EDA pools on a resolvable EDAVirtualNetwork
         #8945 [OPEN · DRAFT]  frisket: EDA client + isolation unit
         #8946 [OPEN · DRAFT]  frisket: port attachment reconciler
     8944 also closes an admission hole: the CEL rule was a per-provider equality, so an
     EDA pool made both sides false and was admitted with no isolation reference at all.

     9124 is the matching one: the policy step passed every non-Aviz provider through
     as in-policy, so widening the enum without it would have disabled governance for
     exactly the provider being added to obtain a guarantee.

  ── OPEN ──
       ▸ forwarding-plane negative test                    — needs a Nokia licence
       ▸ multi-rail and pool scaling                       — needs GPU hardware
       ▸ confirmation of the findings in companion §7      — Nokia EDA engineering
       ▸ release sequencing for the four PRs above         — SpectroCloud

     ✓ Nothing shown today depends on unmerged work to be true — only to ship.

    ▸ Integration companion — §1, the ask, and §7, the findings
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/docs/companion.md#1-the-ask-up-front
    ▸ #8944 — hue-apis: EDA provider + CEL fix
      https://github.com/spectrocloud/mural/pull/8944
    ▸ #9124 — hue: policy-step EDA case
      https://github.com/spectrocloud/mural/pull/9124
    ▸ #8945 — frisket: EDA client + isolation unit
      https://github.com/spectrocloud/mural/pull/8945
    ▸ #8946 — frisket: port attachment reconciler
      https://github.com/spectrocloud/mural/pull/8946
     section 17  ·  page 18 of 19
```

## 17 · Where we have not agreed

```
╔══════════════════════════════════════════════════════════════╗
║  17 · Where we have not agreed                               ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     Two of these, and raising them rather than smoothing them over: both change what gets
     built, and both are cheaper to settle in this room than during an integration.
     ✓ SETTLED, IN YOUR FAVOUR — where a host's switch port is recorded.
     We were populating remote.node on an edge TopoLink purely as a lookup key. You
     told us that is not what an edge link is for, and your own schema says the same:

         kubectl explain topolink.spec
         "Creating a link with only A specified will create an edge interface."

     The empty remote.interfaceResource was the tell — there is no fabric object on
     that side, because a GPU server is not a TopoNode. We were reading topology
     intent as a server inventory. It has been changed: the leaf port moves onto the
     Palette host record and the provider takes it directly. RFC-0021 §4e.

     ✗ STILL OPEN — who configures east/west on the host.
     Your position, as we understood it from the sync — please correct this if we
     have it wrong, because we would rather be corrected than build against it:
     an AI host needs at least two networks configured, north/south plus east/west
     for RDMA and storage, with smart NICs such as BlueField and ConnectX in scope.

     Ours, and the reason for it: our node preparation deliberately leaves the rail
     NICs with no addresses at all, and NV-IPAM with Multus assigns them per workload
     inside the cluster. That tooling already owns rail addressing — configuring the
     same interfaces from the edge agent would collide with it rather than complete it.

     ✓ Most of the surface is not in dispute. Every rail port has to sit in the right
     ✓ tenant's VRF on the fabric, that part is ours, it is modelled one BridgeInterface
     ✓ per port, and it is what this demo has been showing you all along.
     So the open question is narrower than it first sounds: does anything need to
     configure rail interfaces ON THE HOST beyond that, and if so, whose job is it?

     Storage is the same question with the sign reversed: a shared multi-tenant storage
     VLAN needs addresses that do NOT overlap, the opposite of the property this demo
     relies on. The fabric side already handles a host on two networks; the host-side
     tag contract carries exactly one interface, so that half is not expressible yet.

    ▸ Integration companion — §5.1, scope, and §5.2, networks beyond the tenant VLAN
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/docs/companion.md#51-what-we-configure-and-what-we-deliberately-do-not

     section 18  ·  page 19 of 19
```

## 18 · Teardown

```
╔══════════════════════════════════════════════════════════════╗
║  18 · Teardown                                               ║
╚══════════════════════════════════════════════════════════════╝
  ▐ WHY
     This session created real objects on a real fabric, so it has to remove them. There is a
     practical reason as well as a tidy one: this server has exactly one cabled port, and an
     attachment left behind would make the next run fail over it. Putting the fabric back is
     part of the demonstration — a change you cannot cleanly reverse is not one you should be
     making automatically.
     In plain terms: we are showing you the undo, because a system that only knows
     how to create things is not finished.
  Removing what this session created, in dependency order.
     nothing to remove

  Verifying the fabric is back to its starting state:
     ✓ EDA fabric reachable
     ✓ baseline tenants present — tenant-a, tenant-b
     ✓ no leftover objects from previous runs
     ✓ no orphaned bridge interfaces
     ✓ recent EDA transactions healthy
     ✓ Baseline restored — tenant-a and tenant-b untouched throughout.

     The edge host, its Palette registration and the cluster are left running.

    ▸ Integration companion
      https://github.com/blik616287/nokia-eda-tenant-isolation/blob/main/docs/companion.md
    ▸ EDA documentation
      https://docs.eda.dev/

   Thank you.
```
