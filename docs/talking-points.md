# Talking points — the Nokia meeting

Context for the room, not a script. For what to say page by page, see [run-sheet.md](run-sheet.md).

## Where this sits

[RFC-0022](https://github.com/spectrocloud/mural/pull/9206) proposes splitting the single tenant
VLAN into four planes — management, North-South, East-West, storage — and moving the node IP and
primary CNI back onto a management NIC. It is open, not merged.

That changes exactly three claims in this walkthrough, and nothing else. `make demo-fabric` runs the
seventeen pages that make no claim it revisits. `make demo` runs all nineteen, with the three
marked on screen as under active redesign.

**The demo's premise survives it.** The fabric puts a host's port into a tenant; the host tags its
traffic to match. RFC-0022 says the provider needs no dataplane rework, so everything about the EDA
objects, tenancy, route targets, fail-closed behaviour and the ComputePool path is unaffected. What
it supersedes is which interface Kubernetes binds to.

**The host loses nothing.** It already holds both addresses — `192.168.122.206` on management and
`10.210.0.50` on the tenant VLAN. Under RFC-0022 the tenant address stays and becomes the
North-South plane; only `--node-ip` moves. The East-West rail NIC is the only one with no host
address at all, because there the GPU *pods* hold addresses via NV-IPAM.

## How EDA objects map onto the four planes

Two ideas carry all of it:

> **A bridge domain is a network. A bridge interface is one port's membership of one network.**

| Plane | EDA objects |
|---|---|
| Management | none — it is not a tenant segment |
| North-South | `BridgeDomain` + `IRBInterface` (gateway), and a `BridgeInterface` on the leaf port |
| East-West | `BridgeDomain` with **no IRB**, and a `BridgeInterface` on the rail port |
| Storage | `BridgeDomain` + a `BridgeInterface`, on whichever port carries it |

So four planes on one cabled port is four bridge interfaces at four VLAN IDs — ordinary
sub-interface trunking. Nothing new in the provider; a port attachment request is issued per plane
rather than per host.

Two things had to be true for that, and neither was obvious from the schema:

- **A network does not need a gateway.** `VirtualNetwork.spec` has no required fields, so a tenant
  may carry bridge domains and no IRB. Confirmed by creating one: EDA allocated a full EVPN segment
  with no gateway anywhere on the fabric. That is what RoCE wants — layer 2, no routing.
- **One port can belong to several networks at once.** Two attachment requests give two bridge
  interfaces on the same physical port at different VLAN IDs, and the duplicate-port guard still
  refuses two *hosts* on one port.

**What is not settled, and it is the same gap from both ends.** A bridge domain does not know it is
"the East-West one" — that mapping is a per-tenant input. RFC-0022 names the same thing from the
host side: *"the mapping from `vniId` → the selected NIC/VF/VLAN is a required per-tenant input, it
is not implied by the `CIDRPool` alone."* Found independently, which is worth saying.

## Settled on 28 August

**Where a host's switch port is recorded — settled, in Nokia's favour, further than we proposed.**
We were going to carry the leaf port on the Palette host record. Kevin put the better shape and Wim
took it: EDA holds the server-to-port mapping, we send server names and a tenant, and no port
crosses the boundary. *"You tell us which servers you assigned, and then we do the plumbing."* Wim is
returning with the flow and the APIs; Saad expects an API or CRD change to accept "these are the
hosts we want in tenant A".

**East-West addressing has a concrete design.** Nokia produces an addressing plan for the whole
infrastructure as if it were one cluster — unique per NIC per host. We load it into NV-IPAM and
reuse it per tenant; a VRF per customer means every tenant can hold the same addresses. Wim's open
question is whether the address is assigned before or after the tenant is known, because
pre-assigning has a security smell.

**The forwarding-plane test has a path.** Qasim offered to extend the demonstration: two containers,
a tunnel over EVPN VXLAN, end-to-end connectivity between machines in one tenant. That is the one
row our proven/not-proven table cannot close on its own.

**Still open between us, not with Nokia:** pre-map hosts to a tenant, or map on the fly. Saad wants
on-the-fly for elasticity; Tyler wants pre-mapping for reservations and noisy neighbours. Wim's
middle: a node should not be selectable unless its network is up, but the tenant mapping can come
later.

## Three questions worth asking

**Does Phase 1 apply to existing clusters, or new ones only?** It moves the node IP, which on a live
cluster touches etcd peer addresses, cert SANs and the control-plane VIP. It is described as the
correctness fix, which reads as safe to roll out.

**How does the North-South plane handle two tenants with the same address range?** Overlapping
address space is the headline property. If two tenants both announce `10.200.0.0/24` to the border
leaf, do those BGP sessions terminate in separate VRFs? The word "overlap" does not appear in the
RFC, and the advertisement scoping it does specify is a different problem.

**Which story do we tell about where the node IP lives?** The walkthrough says one thing about
today, the RFC proposes another. Both are true; only one of them is obvious to a room hearing both.

## What is still not proven, in either design

- **Traffic genuinely cannot cross between tenants.** Needs real endpoints, `SIMULATE=false` and a
  licence. This is the first ask, and saying it before being asked buys everything else.
- **Multi-rail hosts and pool scaling on real hardware.** Modelled, not exercised.
- **Fleet-scale bootstrap over a real out-of-band transport.** The derivation is demonstrated; the
  channel is plain HTTP on the management network.
- **IPAM for a host's address inside a tenant subnet.** Nothing owns it; it is a reservation.

## East-West on the host — the open disagreement

Nokia's position, as we understood it: an AI host needs north/south and east/west configured, smart
NICs in scope. Ours: node preparation leaves the rail NICs address-less on purpose and NV-IPAM
assigns them per workload, so doing it in the agent would collide with the tooling that owns it.

RFC-0022 does not contradict that — it has Stylus create VFs or leave the NIC bare, with **no IP**,
and NV-IPAM addressing in-cluster. Most of the surface is not in dispute: every rail port has to
sit in the right tenant's VRF on the fabric, and that part is ours and already modelled.
