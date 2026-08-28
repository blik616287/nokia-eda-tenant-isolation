# What to say, page by page

Everything below is spoken. Read it, say it in your own words, move on — no page needs
more than a minute.

```
make demo          enter · p back · r replay · g 12 jump · q quit
```

---

**0 · Clean-slate check**

Before I claim anything, this checks the fabric is in a known state. Leftover state from an
earlier run can make a broken fabric look completely healthy, so nothing in here is claimed
until the starting point is verified.

---

**1 · The edge host, in Palette**

This is an ordinary registered edge host — a machine we built and put our edge agent on.
Everything that makes it special is on this one record: five isolation tags, the agent
version, and the cluster it's running. Those five tags are what the rest of this follows.

**2 · What this host is, and what it is not**

Two things here get called virtualised and they're not the same thing. This host is Linux on
a KVM virtual machine, standing in for a GPU server — it isn't SR Linux, and nothing of ours
runs on a switch. The virtualised SR Linux is the fabric: two leaves and a spine under the
Digital Twin, running the real network OS taking real configuration, with a simulated
forwarding plane. And there's no out-of-band here — this host has a second NIC for
management, but that's a management network, not an out-of-band channel. There's no BMC.

**3 · The tags, and where they came from**

These five values were written into the machine's user-data before it ever registered with
Palette. That ordering matters: the agent takes a snapshot of its tags when it registers and
never looks at them again. Tag a host after the fact and nothing happens.

**4 · Those tag values are VLANs EDA configured**

The tag names VLAN 310, so rather than describe that, here's the provider asking EDA for that
tenant now. Everything coming back — the VNI, the EVI, the route targets — is allocated by
EDA and read back by us. We never compute those. And there's the result on the switch port
this machine is cabled to: VLAN 310, in its own bridge domain.

**5 · The designated interface, on the VM**

Nobody logged into this box — the agent read the tags and built this interface during cloud-init,
before the cluster existed. Worth being precise about where the address came from, because it isn't
obvious: nothing on the fabric issued it. There's no DHCP and no exchange with EDA. The agent took
the address off its own tags. The address is the tag. Under RFC-0022 this interface becomes the
North-South plane rather than the one the node binds to — either way it's built here, from tags, by
the agent.

**6 · The cluster on that host**

Kubernetes came up on the isolated address, not the management one. That's the whole
architectural argument in one line — the node's identity on the network is the tenant
address, and that's only possible because the interface existed before the cluster
bootstrapped.

**7 · Where the cluster's traffic actually goes**

Pod addresses aren't tenant addresses — they come from the CNI's own pool. What makes them
isolated is the interface every packet leaves on. So I'll ask the kernel: traffic to another
node in the tenant subnet goes out the tagged VLAN, sourced from the tenant address. Calico
wraps pod traffic in IPIP with that same outer address, so the tenant VLAN carries the pod
network whatever the pods use inside it. To be precise about what this shows — it proves
traffic leaves on the tenant VLAN. It doesn't prove another tenant can't receive it.

---

**8 · The fabric, and what "isolated" means here**

Your node is in one tenant, and one tenant doesn't demonstrate isolation, so here's a second one
created on the same three switches with the identical gateway address. Same address, same fabric,
two tenants — and what keeps them apart is the route target. Route targets decide which network
imports whose routes, and these two don't import each other's, so neither can learn the other's
addresses at all. It isn't a filter on traffic; the routes are never exchanged. Your node is in the
first one, and nothing in the second can reach it even though both are using the same address.

**19 · The EDA objects, and how planes map onto them**

Five kinds do all of this, and only two are ideas you have to hold: a bridge domain is a network,
and a bridge interface is one port's membership of one network. So a plane is just a bridge domain,
and a host joining a plane is one bridge interface — four planes on one cabled port is four bridge
interfaces at four VLAN IDs, which is ordinary sub-interface trunking and nothing new for us. Two
things had to be true for that and neither was obvious from the schema, so we checked both on this
fabric: a network does not need a gateway, which is what RoCE wants, and one port can belong to
several networks at once. What is not settled is which plane a given VLAN belongs to — a bridge
domain does not know it is the East-West one, so that mapping has to be told to us.

**9 · A GPU host bound to its physical leaf port**

To put a server into a tenant, something has to know which switch port it's plugged into.
There's no API for that question, and the reason is reasonable — EDA models the fabric, and a
GPU server isn't part of the fabric. So we read the cabling records backwards. It works, and
it's the part Nokia reviewed and told us was the wrong place to keep that record. We agree,
and we've changed it: the port moves onto the host record instead.

**10 · Fail-closed behaviour**

This is the failure that worries us most. When isolation doesn't happen, nothing visibly
breaks — the machine boots, joins its cluster, passes every health check, and simply isn't
isolated. No error, no alert. The first person to find out is whoever shouldn't have been able
to reach it. So anything short of complete success is treated as failure, and these tests
prove we write nothing at all rather than half of it.

**11 · The host side — the node IP, and the VIP contract**

This is what those tag values then determined. Kubernetes took its node address from that
interface. And when the control-plane address falls outside the tenant subnet, the agent
refuses to deploy at all — that's the isolation contract enforcing itself, and it's
independent evidence the tags were genuinely parsed rather than just accepted.

**12 · Both halves, at the same time**

The same VLAN on the switch port and on the machine cabled to it, put there by two systems
that never talk to each other and never read each other's result. They agree because both
were told the same thing. If they ever disagreed, nothing would break loudly — which is
exactly the silent failure the previous page is about.

**13 · How Palette drives this — the ComputePool path**

Everything so far was our own code driven directly, which isn't how anyone would use it. A
user picks hosts, groups them into a pool, and asks for that pool to be isolated. This is that
path — what's written, and the one linkage that isn't yet.

**14 · Who writes the host's configuration, at fleet scale**

Every host so far got its isolation settings from a file someone put there by hand. That's
honest for one machine and impossible for a thousand — and it's circular, because you can't
configure a machine's main network connection by talking to it over that connection. So here
the host presents only its MAC address, and is told what it belongs to, derived live from the
fabric. The transport underneath is plain HTTP on the management network — a real deployment
would do this over PXE or an out-of-band installer. We're showing the shape, not the channel.

---

**15 · What is proven, and what is not**

Everything up to here has been a claim, so this is the accounting. One caution about the
evidence itself: Go replays a cached test result exactly, timing included, so a green result
on screen doesn't prove anything ran. The fabric's own transaction count does. What's proven
is tenancy with overlapping address space, host-to-port attachment, fail-closed behaviour, and
Kubernetes on the isolated address. What isn't proven is that traffic genuinely cannot cross
between tenants — that needs real endpoints and a licence, and it's the first thing we're
asking you for.

**16 · Where this stands**

Nothing here was staged for today — it all runs on code that is either already merged or open in
review. The stylus side is merged, the Palette side is in review, and what is still open is on the
screen with whose desk it sits on.

**17 · Where we have not agreed**

Two places. The first is where a host's switch port is recorded — you told us topology intent is the
wrong place for it, your own schema agrees, and we have changed it. The second is still open: who
configures east/west on the host. As we understood it, your position is that an AI host needs both
north/south and east/west configured. Ours is that node preparation leaves the rail NICs
address-less on purpose and NV-IPAM assigns them per workload, so doing it in the agent would
collide with the tooling that already owns it. Most of the surface is not in dispute — every rail
port has to be in the right tenant's VRF on the fabric, and that part is ours and already modelled.
Please correct us if we have your position wrong.

**18 · Teardown**

This created real objects on a real fabric, so it removes them. There's a practical reason as
well — this machine has one cabled port, and anything left behind would make the next run fail
over it. But mostly, a system that only knows how to create things isn't finished.

---

## If you lose the thread

Let me come back to what this is doing: the switch puts this host's port in one tenant's
network, and the host tags its traffic to match. That's the whole mechanism.

I'd have to check — that's outside what I built. Let me take it away.
