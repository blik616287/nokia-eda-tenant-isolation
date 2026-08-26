# Nokia EDA × SpectroCloud PaletteAI — Integration Companion

**Audience:** Nokia EDA engineers. Assumes EVPN, SR Linux and the EDA intent model; does not assume
any knowledge of Palette.

**Environment under discussion:** EDA **26.4.3** (Digital Twin), SR Linux **26.3.1**, 3-node fabric —
2× 7220 IXR-D3L (leaf), 1× 7220 IXR-D5 (spine). Palette edge host running stylus agent-mode
**v4.9.39-rc.4**.

---

## 1. The ask, up front

Four things, in descending order of how much they block us:

1. **Entitlement to run the fabric with `SIMULATE=false`.** Everything we have proven is control
   plane and host configuration. We deliberately do **not** claim traffic cannot cross between
   tenants, because demonstrating that needs real forwarding and therefore a licence. This is the
   single gap between "the integration works" and "isolation is proven".
2. **Confirm or correct §7** — a handful of places where the 26.4 documentation and the live 26.4.3
   API disagree, and two behaviours we rely on that we would rather have confirmed than inferred.
3. **Tell us whether §4.3 is the intended pattern.** We resolve "which leaf port is this server on"
   by reverse-indexing Day-0 edge `TopoLink`s. It works, but it is an inference about intent, and if
   EDA has a supported server-keyed mechanism we would rather use it.
4. **Guidance on multi-rail and scale** — §8.

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

### 4.3 Host → leaf port resolution (**the part we want reviewed**)

EDA has no server-name-keyed API. Nothing answers *"which port is host X on"*. We close that by
reverse-indexing the Day-0 cabling intent: edge `TopoLink`s whose `remote.node` names the host, read
for their `local.interfaceResource`.

```
leaf1  leaf1-ethernet-1-9   remote.node = "lab-gpu-01"
```

Verified on the live fabric: an edge `TopoLink` accepts a `remote.node` naming a host EDA does not
manage, retains `type: edge`, and stays operationally up. No `TopoNode` is required for the remote
side.

**This is an inference about intent, not a contract.** If there is a supported mechanism we should be
using instead, we would rather use it. If there is not, we would like to know that the above is a
reasonable reading and unlikely to change.

### 4.4 Fail-closed, deliberately

Tenant isolation fails in a specific and dangerous way: **a host that is not attached looks identical
to a healthy one.** Nothing errors. So:

- A host whose fabric identity cannot be resolved fails the **entire** pool request, with **no fabric
  write at all**. Attaching the resolvable subset would leave a pool partly isolated while reporting
  success.
- Every rail of a multi-rail host must bind. One missed rail is a real data-plane leak.
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

**7.4 Edge `TopoLink` with an unmanaged `remote.node`** (§4.3) — supported pattern, or coincidence?

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
Modelled — every rail must bind or the request fails — but **not yet exercised on hardware**. This is
where we would most value your guidance: a DGX-class host presents several fabric-facing NICs, and we
want to be sure our one-BridgeInterface-per-port model matches how you expect those to be cabled and
bonded.

**"Does this scale to a real pod?"**
Unknown at fabric scale. Our per-pool work is one `TopoLink` list plus one `BridgeInterface` per port;
we batched the topology read specifically to avoid an N-lists-per-host pattern. We have not tested
against a fabric with thousands of edge links.

---

## 9. Reference

**API groups used:** `services.eda.nokia.com/v2` (VirtualNetwork, BridgeDomain, BridgeInterface,
IRBInterface, Router), `core.eda.nokia.com/v1` (TopoNode, TopoLink, Transaction, TransactionResult).

**Objects created per tenant:** 1 `VirtualNetwork` → EDA materialises `Router`, `BridgeDomain`,
`IRBInterface`, plus the corresponding `*Deployment` and `*State` objects.

**Objects created per pool:** 1 `BridgeInterface` per resolved leaf port.

**Diagnostics:** `kubectl -n eda-system get transactionresults` — `applicationErrors` and
`inputResources` are the fastest route to why an intent did not land.

**Live demo:** `demo-record.sh` in this directory walks all of the above against the running fabric in
about 90 seconds, and tears its own state down afterwards.
