# Nokia EDA × SpectroCloud PaletteAI — Integration Companion

**Audience:** Nokia EDA engineers. Assumes EVPN, SR Linux and the EDA intent model; does not assume
any knowledge of Palette.

**Environment under discussion:** EDA **26.4.3** (Digital Twin), SR Linux **26.3.1**, 3-node fabric —
2× 7220 IXR-D3L (leaf), 1× 7220 IXR-D5 (spine). Palette edge host running stylus agent-mode
**v4.9.39-rc.4**.

---

## 1. The ask, up front

Five things, in descending order of how much they block us:

1. **Entitlement to run the fabric with `SIMULATE=false`.** Everything we have proven is control
   plane and host configuration. We deliberately do **not** claim traffic cannot cross between
   tenants, because demonstrating that needs real forwarding and therefore a licence. This is the
   single gap between "the integration works" and "isolation is proven".
2. **Confirm or correct §7** — a handful of places where the 26.4 documentation and the live 26.4.3
   API disagree, and two behaviours we rely on that we would rather have confirmed than inferred.
3. **The inventory / port-mapping API you offered** (§9). You said EDA can expose host → switch-port
   mapping, either from static inventory or from LLDP discovery. That is the piece we most want, and
   §9 is the contract we would consume — please tell us where it is wrong rather than building to it.
4. **Confirm a bridge domain per tenant is the right shape** (§7.5). Tenants get whole servers or
   racks, so we believe we do not need `MicroSegmentationPolicy` for this model — but you built it,
   and we would rather hear that from you than assume it.
5. **Guidance on multi-rail and scale** — §8.

We are not asking for code changes. Everything below runs against stock EDA.

---

## 2. What we are integrating, and why it is not trivial

PaletteAI manages fleets of GPU hosts and provisions Kubernetes clusters onto them. A *ComputePool*
is a set of hosts allocated to a tenant. The product guarantee we are adding is that two tenants'
pools cannot reach each other **at the fabric**, not merely via Kubernetes NetworkPolicy — including
when both tenants use overlapping IP space.

That guarantee has a hard timing constraint, and it is the reason this is a first-class provider
rather than an add-on:

> Isolation must exist **before Kubernetes starts**. The node IP and the CNI come up *on* the
> isolated interface. Anything delivered after a cluster is healthy is too late to participate.

So the integration has two halves that must agree without knowing about each other:

- **Fabric half** — put the host's leaf port into the right tenant's bridge domain on the right VLAN.
- **Host half** — bring up the matching VLAN sub-interface on the host, before k8s bootstraps.

---

## 3. The EDA model as we actually use it

### 3.1 It is a Kubernetes API

EDA's API *is* a Kubernetes API. `VirtualNetwork`, `BridgeDomain`, `BridgeInterface`, `IRBInterface`,
`Router` are CRDs under `services.eda.nokia.com/v2`; topology and transactions live under
`core.eda.nokia.com/v1`. We talk to it with a dynamic client — no REST shim, no SDK.

This matters for a reason beyond convenience: it means our reconcilers can treat EDA intent as
just another set of owned resources, with the same drift/adopt semantics we use elsewhere.

### 3.2 One `VirtualNetwork` per tenant, not composed parts

`VirtualNetwork.spec` carries four collections:

```
routers[]           bridgeDomains[]        bridgeInterfaces[]        irbInterfaces[]
```

We create **one** `VirtualNetwork` per isolation unit and let EDA materialise the IP-VRF, MAC-VRF and
IRB together, lifecycle-bound. An earlier design composed `Router` + `BridgeDomain` + `IRBInterface`
separately; reading the live CRD showed that to be unnecessary work and a worse failure model — the
parts could partially exist.

### 3.3 Identifiers come **from** EDA, never from us

VNI, EVI and route targets are allocated by EDA's own allocator and read back:

```
tenant-a-bd   vni=200  evi=100  importTarget=target:1:100  exportTarget=target:1:100
tenant-b-bd   vni=201  evi=101  importTarget=target:1:101  exportTarget=target:1:101
```

Both tenants' IRBs answer at the **same** gateway (`10.200.0.1/24`). That is the property the whole
feature exists to provide: overlapping tenant address space separated by EVPN. If our numbers were
ever identical run-to-run it would mean we were computing them, which is the bug we designed against.

### 3.4 Readiness is "an EVI was allocated", not `operationalState: Up`

This is worth stating because it is not visible from the schema. A bridge domain with nothing bound
to it sits at `operationalState: Unknown` with `numSubinterfaces: 0`. It only goes `Up` once a
sub-interface exists. Gating unit readiness on `Up` would leave every tenant permanently not-ready
until its first pool arrived — a deadlock, since the pool attaches *to* the unit.

So: **unit ready ⇔ EDA allocated an EVI.** Attachment readiness is separate (§4.4).

### 3.5 Transactions are batched, and one bad intent fails the batch

`core.eda.nokia.com/v1` exposes `transactions`, `transactionresults`, `transactionpipelines`.
`transactionresults` is the diagnostic of record — it carries `inputResources` (with actions) and
`applicationErrors` per transaction.

The operationally important consequence, which cost us 44 minutes: **a dangling reference fails every
transaction in the batch, not just its own.** Delete a `VirtualNetwork` while one of its
`BridgeInterface`s still exists and the orphan yields

```
missing dependency of type BridgeDomain with name <bd>
```

on every subsequent transaction until it is removed by hand — while the fabric otherwise looks
healthy. Our teardown therefore always deletes **BridgeInterface → VirtualNetwork → BridgeDomain**.

---

## 4. What we built

Two CRDs in our network-isolation operator, mirroring the shape of our existing Aviz provider.

### 4.1 `EDAVirtualNetwork` — the isolation unit

One per tenant. Reconciles to one EDA `VirtualNetwork`; reads back bridge domain name, VNI, EVI and
route target into status. Supports **adopt** (an operator-authored VN already exists) as well as
**managed** creation, so a fabric team can pre-author tenants if they prefer.

### 4.2 `EDAPortAttachmentRequest` — the per-pool binding

One per ComputePool. Resolves every host in the pool to a physical leaf port and creates one
`BridgeInterface` per port, on the subnet's VLAN.

### 4.3 Host to leaf port resolution (**the part we are replacing**)

EDA has no server-name-keyed API. Nothing answers *"which port is host X on"*. We close that by
reverse-indexing the Day-0 cabling intent: edge `TopoLink`s whose `remote.node` names the host, read
for their `local.interfaceResource`.

```
leaf1  leaf1-ethernet-1-9   remote.node = "lab-gpu-01"
```

Verified on the live fabric: an edge `TopoLink` accepts a `remote.node` naming a host EDA does not
manage, retains `type: edge`, and stays operationally up. No `TopoNode` is required for the remote
side.

**This is what we built, and we are replacing it.** It was an inference about intent rather than a
contract, and your feedback — plus your own schema, which says an edge link should specify the local
side only — says it was the wrong one. §7.4 has the change we are making and the LLDP question we
would rather solve it with.

### 4.4 Fail-closed, deliberately

Tenant isolation fails in a specific and dangerous way: **a host that is not attached looks identical
to a healthy one.** Nothing errors. So:

- A host whose fabric identity cannot be resolved fails the **entire** pool request, with **no fabric
  write at all**. Attaching the resolvable subset would leave a pool partly isolated while reporting
  success.
- Every rail of a multi-rail host must bind **on the fabric**. One missed rail is a real
  data-plane leak. Note this is the switch-port side only — see §5.1 for the division of
  labour on the host, which is deliberately not ours.
- A pool is `Attached` only once **every** binding reports operational *on the fabric*. EDA accepts a
  `BridgeInterface` long before the transaction programming it commits, so an API success is not
  evidence of anything — we read back `numSubinterfaces` on the bridge domain instead.
- Two hosts resolving to the same physical port fails loudly rather than silently collapsing.

Each of these is covered by a test that was confirmed to fail when the behaviour is removed.

---

## 5. The host half

Palette's edge agent (*stylus*) reads five tags off the edge-host record and builds the matching
interface in cloud-init:

```yaml
net-iso-provider: eda
net-iso-interface: enp2s0
net-iso-vlan: "310"
net-iso-subnet-ipv4: 10.210.0.50
net-iso-subnet-prefix-length: "24"
```

Result on the host — nobody logged in, the parent NIC had no address of its own:

```
enp2s0.310@enp2s0   vlan protocol 802.1Q id 310   UP   10.210.0.50/24
```

And then the part that matters:

```
"node-ip":["10.210.0.50"]   "node-external-ip":["10.210.0.50"]
```

Kubernetes comes up **on the isolated address**. That is the timing constraint from §2, satisfied.

Two behaviours worth knowing if you reproduce this: tags are **snapshotted at first registration** and
never re-read, so they must be present before the host registers; and the agent fail-closes when the
control-plane VIP falls outside the tenant CIDR (`invalid vip ... is not in the CIDR 10.210.0.50/24`),
which is a useful independent signal that it really parsed the tags.

**Tags are the current mechanism, not the intended one.** The direction on our side is to carry this
on the edge-host record through the platform API rather than as labels. Nothing in the fabric half
changes if that happens — the provider still resolves a pool to leaf ports and writes bridge
interfaces — but the host half would be configured from a record rather than from tags. Worth knowing
if you are reading the tag names as a long-term contract; they are not one.

### 5.1 What we configure, and what we deliberately do not

Worth stating precisely, because "full network isolation" can mean several different things and we
only claim one of them.

The deployment model is **whole servers, usually whole racks, per customer** — no sharing of host
hardware between tenants. Given that, isolating customer A's cluster from customer B's needs exactly
one thing: **EVPN on the fabric, so the traffic never meets.** Everything else follows from it, and
the useful consequence is that every customer can reuse the same east/west addressing, because each
sits in its own routing VRF and cannot see the others. That is the property demonstrated in §3.3 —
two tenants at the identical gateway, separated by EVPN, not by address planning.

| Interface | Who configures it | In this integration |
|---|---|---|
| **Fabric ports** (all of them, including rails) | EDA, from our intent | **Ours.** One `BridgeInterface` per port, in the tenant's bridge domain |
| **Node / CNI interface** | the Palette edge agent, from isolation tags | **Ours.** §5 — the VLAN sub-interface the node and CNI come up on |
| **East/west rails, host side** | NV-IPAM + Multus, per workload | **Not ours, by design.** Node-prep leaves rail NICs without addresses; Kubernetes assigns them inside the container |
| **Pod network** | the CNI, within one cluster | **Out of scope.** A cluster belongs to one tenant, so there is no pod-level multi-tenancy to solve |
| **Management / out-of-band** | site infrastructure | **Unsolved at scale** — see below |

So the honest one-line scope: **we put the right switch ports in the right tenant's VRF, and we bring
up the node interface on the matching VLAN.** We do not configure rails on the host.

**This is where the two sides of the conversation currently disagree, and it is worth surfacing
rather than smoothing over.** Nokia's position is that an AI deployment needs at least two networks
configured per host — north/south, and east/west for RDMA and storage — with smart NICs (BlueField,
ConnectX) in scope. Our own network architecture takes the opposite view: node-prep deliberately
leaves rail NICs address-less and NV-IPAM assigns them per workload inside the cluster, so the host
side of east/west is not the edge agent's job and doing it there would collide with the tooling that
already owns it.

Both can be true at once, and we think they are: **the fabric must put every rail port in the right
tenant's VRF** — that part is squarely ours and already modelled — **while the host side of the rails
stays with NV-IPAM.** What is genuinely unresolved is whether anything needs to configure rail
interfaces *on the host* beyond that, and if so, whether that belongs to the edge agent at all. We
would rather settle that explicitly than discover it in an integration.

**One ambiguity worth naming, because our lab hides it.** "The interface we configure" is described
two ways in our own conversations: as the north/south management NIC, and as the node/CNI interface.
In a production host those are usually the *same* NIC — the machine has one general-purpose interface
plus its rails. In the lab they are deliberately two: one NIC keeps a management path so we can reach
the host, and the isolated VLAN carries the node address. That makes the demo easier than production
in a specific way, and it is the reason the next paragraph is a real gap rather than a theoretical
one.

**The bootstrap dependency, stated plainly.** Configuring a host's primary interface from a
controller the host reaches *over that interface* is circular. We avoid it here by carrying the
isolation tags in cloud-init, so the host knows its VLAN and address before it talks to anything —
the same shape as storing per-server addressing in a provisioning database and having it be correct
at deploy time. What we have **not** solved is doing that at fleet scale without a PXE or
out-of-band provisioning path underneath. That is a real gap, it is not an EDA gap, and it is not
one this demo closes. DPU-based addressing would sidestep it — see §8 for why we are not
counting on that.

**Why EDA and not the existing provider.** Multi-tenant EVPN on switches is not new — the providers
already integrated do it. The constraint is vendor coverage: today's integration is limited to one
switch vendor's hardware. EDA is what makes the same guarantee available on SR Linux, which is the
entire reason this work exists.

### 5.2 Networks beyond the tenant VLAN — where this stops

Everything above concerns one network: the tenant VLAN the node comes up on. Real deployments have
more, and the shape is not ours to choose. One hoster runs a single large multi-tenant storage
environment where every customer needs a **shared** storage VLAN with **non-conflicting** addresses.
Another gives each customer storage native to their own environment with no sharing at all. There is
no single answer — every site implements something different.

That matters because a shared network inverts the property §5.1 relies on. Per-tenant isolation
*wants* overlapping address space; a shared storage VLAN *forbids* it, because everyone is talking to
the same targets. The two need opposite IPAM disciplines.

We checked how much of this the current model already supports, rather than assuming:

**The fabric side already handles it.** A host can sit on several networks at once. Two
`EDAPortAttachmentRequest`s — one for the tenant, one for shared storage — produce two
`BridgeInterface`s on the *same* physical port with different VLAN IDs, which is ordinary
sub-interface trunking. Our duplicate-port guard is per-request and keys on the derived binding name,
so it correctly rejects two hosts on one port without blocking one host on one port in two networks.
Nothing needs to change here.

**The host side does not.** The isolation tag contract carries exactly one interface —
`net-iso-interface`, `net-iso-vlan`, one address — and the agent's internal representation is a
single struct, not a list. The documented meaning of that address is that it *becomes the node IP*.
So the node's tenant VLAN is expressible and a second, shared VLAN is not. Supporting one would mean
extending the tag contract, which is a change in the edge agent rather than in this provider.

**IPAM is undefined for the shared case.** We allocate tenant gateway addresses on the assumption
that overlap between tenants is fine, because that is the whole point. A shared network needs
allocation that is unique *across* tenants. Nothing in the model currently distinguishes the two, and
it should not be inferred from the network's name.

**The design principle we would rather hold to.** Do not encode a storage topology in the provider.
It expresses one thing — *attach this pool's ports to this named network* — and which networks are
shared, which are isolated, and how each is addressed stays a property of the deployment. That keeps
the provider correct across sites that have arranged things differently, which on this evidence is
all of them.

---

## 6. What is proven, and what is not

| Claim | Status |
|---|---|
| EVPN tenancy with overlapping address space, distinct VNI/EVI/RT | **Proven** on the live fabric |
| Host resolved to its physical leaf port and attached | **Proven**, fabric independently confirms the sub-interface |
| Fail-closed on unresolvable hosts, duplicate ports, partial binds | **Proven** by test, each verified to fail when removed |
| Host raises the matching VLAN from Palette tags | **Proven** |
| Kubernetes runs on the isolated address | **Proven** |
| **Traffic cannot cross between tenants** | **NOT proven** — needs `SIMULATE=false` + licence |
| Multi-rail hosts, pool scaling on real hardware | **NOT proven** — needs hardware |
| Fleet-scale bootstrap without PXE / out-of-band provisioning | **NOT proven** — see §5.1 |
| A host on more than one network (e.g. shared storage VLAN) | **Fabric side supported; host side not** — see §5.2 |

We are explicit about the last two because the first five are stronger if we are not overstating.

---

## 7. Findings for Nokia — please confirm or correct

**7.1 Documentation and live API disagree in several places.** We derived every schema from the live
26.4.3 API after finding mismatches. The one with real consequences:

> Bridge-domain status is **`numSubinterfaces`**, not the plausible-looking `totalSubInterfaces`.

We read a silent zero until this was checked against the cluster. The full status set we rely on:
`vni`, `evi`, `importTarget`, `exportTarget`, `numNodes`, `numSubinterfaces`,
`numSubinterfacesOperDown`, `operationalState`, `tunnelIndex`, `lastChangeTime`.

**7.2 A subnet name becomes an `IRBInterface` CR name.** Two `VirtualNetwork`s each declaring a subnet
named `compute` collide:

```
CR services.eda.nokia.com/v2/IRBInterface/compute has conflicting updates
```

Overlapping *gateways* are fine — `tenant-a` and `tenant-b` both use `10.200.0.1/24` — it is the CR
name that clashes. Is namespacing subnet names per-VirtualNetwork intended, or should we prefix?

**7.3 Orphaned `BridgeInterface` poisons the whole transaction queue** (§3.5). Is failing the entire
batch on one dangling dependency the intended behaviour, or should the offending intent be isolated?

**7.4 Edge `TopoLink` with an unmanaged `remote.node`** (§4.3) — **you told us no, and we agree.**
We are changing it; §4.3 above describes what we built, this is what we are replacing it with.

Your schema makes the case better than the feedback did:

> `kubectl explain topolink.spec` — *"Creating a link with only A specified will create an edge interface."*

For an edge link the model is to specify the local side and omit `remote`. We populate it anyway,
purely as a lookup key, and the empty `remote.interfaceResource` gives it away — there is no fabric
object on that side, because a GPU host is not a `TopoNode`. That the API tolerates it is not an
argument that it is intended, and on real hardware nobody would have populated that field for us.

**What we are changing it to.** The port attachment takes the leaf interface directly —
`leaf1-ethernet-1-9` — and passes it to `BridgeInterface.spec.interface`, which is what you wanted
from us in the first place. The server↔port cabling record moves into PaletteAI's compute inventory,
where a machine's cabling record belongs and where you do not have to maintain it. **We then read
nothing from your topology intent at all**, which is the boundary we said we were respecting and
were not quite.

**Where we would rather end up: LLDP.** The fabric-native answer to "which port is this host on" is
neighbour discovery, with no mapping maintained on either side. We could not build on it here:
`LldpOverlay` is a UI overlay over the physical topology rather than a query API, we found no LLDP
neighbour field on `interfacestate`, and Digital Twin nodes will not peer LLDP with a real host.
**Is there a supported way to read LLDP neighbour state programmatically?** If so, that is the
version we want, and the port-on-the-request above becomes the fallback for hosts that cannot run
LLDP.

**7.5 Microsegmentation — do we need it at all?**

You have a first-class segmentation model we do not use: `GroupTag`, `AssociationPolicy` (with
`bridgeInterfaceSelectors` / `vlanSelectors`) and `MicroSegmentationPolicy` in
`microsegmentation.eda.nokia.com/v1alpha1`.

Our read is that we do not need it for the guarantee in §5.1, and we want to check that with you
rather than assume it. Tenants get whole servers or whole racks, so there is no intra-tenant boundary
to police; a bridge domain per tenant already means the traffic never meets, and
`MicroSegmentationPolicy` governs reachability *within* a network instance — a different and softer
property than having no path at all.

**Two things we would like confirmed.** First, that separate bridge domains per tenant is the shape
you would expect for this deployment model, rather than one shared instance with policy between
group tags. Second, whether there is anything in your roadmap that would make the policy model the
preferred route later — if so we would rather know before the provider ships than after.

---

## 8. Questions we expect, answered

**"Is this just NetworkPolicy with extra steps?"**
No. NetworkPolicy is enforced by the CNI, inside the cluster, after it is running. This is an EVPN
bridge domain on a leaf port, before the node has an IP. A compromised node cannot opt out of it.

**"Why not let the fabric team pre-author tenants and have Palette just reference them?"**
That is supported — the adopt path in §4.1. Managed creation exists so a Palette operator can
self-serve where the org wants that; adoption exists so a fabric team can retain control.

**"What happens when a pool shrinks?"**
The attachment reconciler computes retained bindings as *everything tracked minus confirmed
detached*, so a failed detach cannot silently drop a binding from tracking and leave a stranded
`BridgeInterface` on the fabric.

**"What if EDA is unreachable mid-reconcile?"**
Status is persisted before fabric writes ("record before write"), so a crash between the two leaves a
reservation we can reconcile from, not an orphan we have forgotten about.

**"Multi-rail GPU hosts?"**
On the fabric: modelled — every rail must bind or the request fails — but **not yet exercised on
hardware**. An HGX-class host presents eight rails, and we want to be sure one-`BridgeInterface`-
per-port matches how you expect those cabled and bonded.

On the host: **not our job, by design.** Our own node-prep leaves east/west NICs without addresses
and moves that into Kubernetes desired state via NV-IPAM and Multus, so rail addressing is assigned
per-workload inside the cluster. The fabric still has to put those rail ports in the right tenant's
VRF; nothing configures them on the host. See §5.1.

**"What about DPUs and smart NICs?"**
You raised BlueField and ConnectX in the sync, so: multi-tenancy via DPUs is technically possible
through NVIDIA HBN, deployed as a DPF Zero Trust solution — a dedicated Kubernetes cluster running
DPF that controls the DPUs over their out-of-band management ports. Fabric providers can also drive
that natively, generally with better tooling around it.

It has one property we would genuinely value: **address assignment happens over DHCP**, which
sidesteps the bootstrap dependency in §5.1 — no need to hand a host its address before it can reach
anything. That is the cleanest answer to the scale problem we have seen.

We are not designing around it, for a reason that is about deployments rather than technology. Most
customers with this hardware do not use the DPU functionality and are not confident in it, and many
sites are not cabled for it at all — out-of-band switch port capacity is routinely under-provisioned
relative to the number of DPU management ports, so the ports physically cannot be wired up. Outside
a handful of specialist providers it is rarely deployed in practice.

So we treat it as an **opportunistic optimisation, not a prerequisite**: where a customer runs DPUs,
the fabric side of this integration is unchanged and the host side gets easier. Where they do not —
which is most places — nothing above depends on it.

**"Does this scale to a real pod?"**
Unknown at fabric scale. Our per-pool work is one `TopoLink` list plus one `BridgeInterface` per port;
we batched the topology read specifically to avoid an N-lists-per-host pattern. We have not tested
against a fabric with thousands of edge links.

---

## 9. The inventory contract we would consume

You offered host → switch-port mapping from EDA, either static inventory or LLDP discovery. This is
what we would call and what we would do with each field, written as a proposal so you can correct it
rather than guess at our needs.

**What we need, per host:**

| Field | Why we need it | Consequence if absent |
|---|---|---|
| host identifier | join key back to our compute inventory | cannot correlate at all |
| leaf switch + interface (e.g. `leaf1`, `ethernet-1-9`) | becomes `BridgeInterface.spec.interface` | the host cannot be attached |
| all interfaces for that host, not just one | an HGX-class host has eight rails; every one must land in the tenant's VRF | a missed rail is a silent data-plane leak |
| whether the mapping was **discovered** or **declared** | we would treat a stale LLDP entry differently from an operator-declared one | we cannot reason about staleness |
| last-seen / observed-at, for discovered entries | decide whether to trust a mapping for a host that has been down | we would have to trust it blindly |

**What we do not need from you:** subnet, VLAN ID or mask. Those come from the tenant's isolation
unit on our side — the VLAN is a property of which tenant the pool belongs to, not of the cabling.
If you would rather own subnet allocation as well, that is a larger conversation and worth having
explicitly (§8) rather than by implication.

**Two properties that matter more than the schema.** First, we fail closed: a host we cannot map
fails the *entire* pool request with no fabric write, so a partial or silently-empty response is
safer than a guessed one — please prefer an error to an empty list. Second, we would poll this on
reconcile rather than cache it, so a mapping that changes when a machine is re-cabled should be
reflected without us being told.

**A cheaper variant we could not verify.** LLDP can carry VLAN in the IEEE 802.1 TLVs, and a
colleague reports having used that in production: if the API returns a tenant's VLAN ID, the host
could find its own fabric-facing NIC by matching it, and neither side would need a hostname-to-port
table. We are flagging it rather than proposing it, because on this fabric we could not confirm it —
no LLDP neighbour state is exposed on `interfacestate`, the only LLDP resource is a UI overlay, and a
colleague on the other provider could not get it working either. **Does SR Linux advertise the 802.1
VLAN TLVs, and is that neighbour state readable through the API?** If yes, this contract gets much
smaller.

**Until it exists**, the leaf port is supplied on the attachment request from our own inventory
(§7.4). That keeps us unblocked and is the static-inventory case in your own framing; the API
replaces the hand-maintained half of it.

---

## 10. Reference

**API groups used:** `services.eda.nokia.com/v2` (VirtualNetwork, BridgeDomain, BridgeInterface,
IRBInterface, Router), `core.eda.nokia.com/v1` (TopoNode, TopoLink, Transaction, TransactionResult).

**Objects created per tenant:** 1 `VirtualNetwork` → EDA materialises `Router`, `BridgeDomain`,
`IRBInterface`, plus the corresponding `*Deployment` and `*State` objects.

**Objects created per pool:** 1 `BridgeInterface` per resolved leaf port.

**Diagnostics:** `kubectl -n eda-system get transactionresults` — `applicationErrors` and
`inputResources` are the fastest route to why an intent did not land.

**Live demo:** `demo-record.sh` in this directory walks all of the above against the running fabric in
about 90 seconds, and tears its own state down afterwards.
