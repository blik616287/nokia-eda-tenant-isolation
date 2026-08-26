# Nokia EDA + PaletteAI — Integration Verification Summary

**Date:** 25 August 2026 · **Status:** fabric-side and host-side both verified — fabric against a live EDA 26.4.3 cluster, host side against stylus agent-mode v4.9.39-rc.4

---

## 1. What was built

A first-class **network-isolation provider for Nokia EDA** inside PaletteAI's isolation operator, alongside the existing Aviz provider. Two Kubernetes controllers:

| Component | Responsibility |
|---|---|
| `EDAVirtualNetwork` | The isolation unit — one tenant VPC. Creates an EDA `VirtualNetwork`, which emits the IP-VRF, MAC-VRF and IRB interfaces together as one lifecycle-bound object. |
| `EDAPortAttachmentRequest` | Binds a GPU pool's hosts into that tenant's bridge domain — one `BridgeInterface` per leaf port. |

The provider talks to EDA through the Kubernetes API directly, because EDA's API *is* a Kubernetes API — `VirtualNetwork`, `BridgeDomain`, `BridgeInterface` and `TopoLink` are all CRDs. No REST shim is involved.

## 2. Test environment

- **Nokia EDA 26.4.3** (Digital Twin), 3-node SR Linux fabric — 2× leaf (7220 IXR-D3L), 1× spine (7220 IXR-D5)
- All nodes onboarded, `Connected` / `Synced`
- Verification runs against this cluster directly, not against mocks

## 3. Results

### 3.1 Tenant isolation — verified

Two tenants provisioned through the provider:

| Tenant | Bridge domain | VNI | EVI | Route target | Gateway |
|---|---|---|---|---|---|
| tenant-a | `tenant-a-bd` | 200 | 100 | `target:1:100` | `10.200.0.1/24` |
| tenant-b | `tenant-b-bd` | 201 | 101 | `target:1:101` | `10.200.0.1/24` |

Both tenants answer at the **identical gateway address** while carrying distinct VNI, EVI and route targets. This is overlapping tenant address space separated by EVPN — the core multi-tenancy property, demonstrated on the fabric rather than asserted.

EVI, VNI and route targets are **allocated by EDA** and read back by the provider. They are never computed on the PaletteAI side; doing so would fight EDA's own allocator.

### 3.2 GPU host attachment — verified

A host is bound to its leaf port end to end:

```
RESOLVED  lab-gpu-01 -> leaf=leaf1 interface=leaf1-ethernet-1-9
BOUND     bridgeInterface=...-leaf1-ethernet-1-9 vlan=310 state=Up
CONFIRMS  bridge domain reports subifs=1 down=0 nodes=1 state=Up
```

Three separate facts, and the third is the significant one: the **bridge domain independently reports** the new sub-interface. That is the fabric confirming the change, not the provider reporting its own write back to itself.

### 3.3 Host-to-port resolution

EDA has no server-name-keyed API — nothing answers *"which port is host X on"*. The provider closes this by reverse-indexing the Day-0 cabling intent: edge `TopoLink`s whose `remote.node` names the host, read for their `local.interfaceResource`.

Verified on the live fabric: an edge `TopoLink` accepts a `remote.node` naming a host EDA does not manage, retains type `edge`, and stays operationally up. No `TopoNode` is required for the remote side.

### 3.4 Safety properties

Tenant isolation fails in a specific and dangerous way: a host that is *not* attached looks identical to one that is healthy. The provider is therefore **fail-closed** throughout:

- A host whose fabric identity cannot be resolved fails the **entire** pool request, with **no fabric write at all**. Attaching the resolvable subset would leave a pool partly isolated while reporting success.
- Every rail of a multi-rail host must bind. Missing one is a data-plane leak nothing downstream would detect.
- A pool is only `Attached` once **every** binding reports operational on the fabric. EDA accepts a `BridgeInterface` long before the transaction programming it commits, so an API success is not evidence of anything.
- Two hosts resolving to the same physical port fails loudly rather than silently collapsing.

Each of these is covered by an automated test that was confirmed to fail when the behaviour is removed.

## 4. Method note

Every schema in the implementation was derived from the **live EDA API**, not from the 26.4 documentation, after the two were found to disagree in seven separate places. One example with real consequences: the bridge-domain status field is `numSubinterfaces`, not the plausible-looking `totalSubInterfaces` — the provider read a silent zero until this was checked against the cluster.

This is worth stating because it shaped the approach: for this integration, the live API is treated as the source of truth and the documentation as a hint.

## 5. What is **not** yet proven

**Forwarding-plane isolation.** Tenancy semantics are proven above — distinct EVI/VNI/route-targets with overlapping address space — but demonstrating that traffic genuinely *cannot* cross between tenants requires real endpoints, which requires running the fabric with `SIMULATE=false` and a licence. This is a licensing question, not a technical blocker.

## 6. Host-side VLAN attachment — verified

Verified on 25 August 2026 with stylus agent-mode **v4.9.39-rc.4** on edge host `lab-gpu-01`.

Five `net-iso-*` tags were placed in the host's cloud-init userdata *before first registration* — tags are snapshotted at registration and never re-read — and round-tripped into Palette as edge-host labels. The agent then resolved them without further input:

```
enp2s0.310@enp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> vlan protocol 802.1Q id 310
enp2s0.310@enp2s0  UP  10.210.0.50/24
```

The sub-interface matches the tags exactly: `net-iso-interface=enp2s0`, `net-iso-vlan=310`, `net-iso-subnet-ipv4=10.210.0.50`, `net-iso-subnet-prefix-length=24`. The parent NIC had no address of its own.

The consequential result is what Kubernetes then did with it:

```
"node-ip":["10.210.0.50"]   "node-external-ip":["10.210.0.50"]   "tls-san":["10.210.0.100"]
```

**The node comes up on the isolated VLAN address, not the management interface.** This is the concrete form of the argument that isolation must be a first-class provider rather than profile-bundle content: it is established in cloud-init, before Kubernetes starts, whereas bundle content is delivered only once a cluster is already healthy.

Two behaviours worth recording, both fail-closed:

- The agent refuses to deploy when the control-plane VIP falls outside the tenant subnet — `invalid vip. Cannot proceed with upgrade: VIP 192.168.122.171 is not in the CIDR 10.210.0.50/24`. It is genuinely parsing the tags, not merely accepting them.
- Running a specific agent build requires `stylus.skipStylusUpgrade: true` in the userdata. Otherwise the agent reconciles its version down to whatever the Palette instance declares — 4.8.20 on this one, which predates the `net-iso-*` tags and ignores them silently.

## 7. Both halves together — verified

The fabric and host sides were brought up simultaneously and left in place:

| | Fabric side | Host side |
|---|---|---|
| Put there by | the provider's `EDAPortAttachmentRequest` | stylus, from Palette edge-host tags |
| Object | `BridgeInterface nokia-demo-pool-leaf1-ethernet-1-9` | `enp2s0.310@enp2s0` |
| Port / NIC | `leaf1-ethernet-1-9` | `enp2s0` |
| VLAN | 310 | 802.1Q id 310 |
| Address | gateway `10.210.0.1/24` | `10.210.0.50/24` |
| State | `Up` | `UP` |

The tenant bridge domain `nokia-demo-bd` carries VNI 207, EVI 107, route target `target:1:107` — all allocated by EDA — and independently reports one operational sub-interface.

Neither half has any knowledge of the other. They agree because both were derived from the same declared intent: the provider resolved the host to its leaf port through the Day-0 cabling intent, and the agent resolved the same host's tags into a local interface.

## 8. Next steps

1. Forwarding-plane negative test, subject to licensing.
2. Multi-rail and pool-scaling behaviour on real hardware, where a host presents several fabric-facing NICs.
3. Wire the two halves to a single trigger. Today the fabric side is driven by the provider and the host side by cluster deployment; they are consistent but separately initiated.

---

### Summary

Both halves of the integration are verified. On the fabric: tenants are provisioned with correct EVPN isolation identifiers against a live EDA 26.4.3 cluster, GPU hosts are resolved to their leaf ports and bound into the right tenant's bridge domain, and the fabric independently confirms each change. On the host: an edge host tagged through Palette brings up its own 802.1Q sub-interface on the tenant NIC, and Kubernetes comes up on that isolated address rather than the management one.

What remains is to show the two together in a single flow — each is proven separately today — and, subject to licensing, a forwarding-plane negative test.
