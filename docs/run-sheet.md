# Run sheet — eighteen pages

One or two sentences per page. Say the sentence, let the screen carry the detail, move on.

```
make demo          enter · p back · r replay · g 12 jump · q quit
make verify        the transaction count, if anyone wants the run proved live
```

---

## Before anyone is watching

**0 · Clean-slate check**
Before I claim anything, this checks the fabric is in a known state — leftover state can make a
broken fabric look perfectly healthy.

---

## What we have · 1–7

**1 · The edge host, in Palette**
An ordinary registered edge host. Everything that makes it special is on this one record: five
isolation tags, the agent version, and the cluster it is running.

**2 · What this host is, and what it is not** — *the one to get right*
The host is Linux on KVM — **not** SR Linux, and nothing of ours runs on a switch. The virtualised
SR Linux is the **fabric**: three switches under the Digital Twin, real NOS, simulated forwarding
plane.
And there is **no out-of-band here** — a management network is not an out-of-band channel. That
comes back on page 14.

**3 · The tags, and where they came from**
These five values were written before the machine ever registered. The agent takes a snapshot of its
tags at registration and never looks again — tag it late and nothing happens.

**4 · Those tag values are VLANs EDA configured** — *~60s, runs live*
The tag names VLAN 310, so here is the provider asking EDA for that tenant. EDA allocates the VNI,
EVI and route targets — we read them back, we never compute them.
And there it is, on the switch port this machine is cabled to.

**5 · The designated interface, on the VM**
Nobody logged into this box — the agent read the tags and built this interface during cloud-init,
before Kubernetes existed on it.
The address came *from the tag*, not from DHCP. Which is exactly why we check the fabric and never
the host.

**6 · The cluster on that host**
Kubernetes came up on the isolated address, not the management one. That is only possible because
the interface existed *before* the cluster bootstrapped.

**7 · Where the cluster's traffic actually goes** — *rehearse this one*
Pod addresses are not tenant addresses. What makes them isolated is the interface every packet
leaves on — ask the kernel, and traffic to a peer goes out `enp2s0.310` sourced from the tenant
address.
Say the limit yourself: this shows egress, not blocking.

---

## How it works · 8–14

**8 · The fabric, and what "isolated" means here**
Isolation here is EVPN, not a firewall rule. Two tenants answering at the same gateway address,
separated by bridge domains — that is the property this whole thing exists to provide.

**9 · A GPU host bound to its physical leaf port** — *~65s, runs live*
Something has to know which switch port a server is plugged into, and there is no API for that
question. We read the cabling records backwards.
Concede it before they raise it: Nokia said that is the wrong place to keep that record, and we
agree — it is changing.

**10 · Fail-closed behaviour**
When isolation fails, nothing visibly breaks — an unattached host looks exactly like a healthy one.
So anything short of complete success is treated as failure, and we write nothing rather than half.

**11 · The host side — the node IP, and the VIP contract**
If the control-plane address falls outside the tenant subnet, the agent refuses to deploy at all.
That is the isolation contract enforcing itself, and it is independent proof the tags were parsed
rather than merely accepted.

**12 · Both halves, at the same time**
The same VLAN on the switch port and on the machine cabled to it, put there by two systems that
never talk to each other. They agree because both were told the same thing.

**13 · How Palette drives this — the ComputePool path**
Everything so far was the engine on a test bench. This is how someone would actually drive it — pick
hosts, make a pool, ask for isolation — and one linkage is still unwritten.

**14 · Who writes the host's configuration, at fleet scale**
Every host so far got its settings from a file someone put there by hand. That does not scale, and
it is circular — you cannot configure a machine's main connection by talking to it over that
connection.
Here the host presents only its MAC and is told what it is, derived live from the fabric.

---

## Closing · 15–17

**15 · What is proven, and what is not**
The accounting. Do not trust the test output — trust the fabric's own transaction count, because
nothing on our side can fake it.
Forwarding-plane isolation is **not proven**. That needs a licence, and it is our first ask.

**16 · Where this stands** — *the important page*
Nothing here was staged for today. Two places we have not agreed: where a host's switch port is
recorded — where you were right, and we have changed it — and east/west on the host, which is
still open.

**17 · Teardown**
It made real objects on a real fabric, so it removes them. A system that only knows how to create
things is not finished.

---

## When you lose the thread

> "Let me come back to what this is doing: the switch puts this host's port in one tenant's network,
> and the host tags its traffic to match. That's the whole mechanism."

> "I'd have to check — that's outside what I built. Let me take it away."

Two kinds of hard question, two different moves. **EDA internals** — take it away; there is no
position to defend. **Network architecture** — rails, storage, DPUs, bootstrap — there *is* a
position, it is the network architecture team's, and reporting it is legitimate. Say whose it is.
