# EDA + PaletteAI — Live Demo Runbook

The walkthrough is `make demo`: nineteen pages, one section per page, driven live against the
fabric. `enter` advances, `p` goes back, `r` replays the current page, `g 12` jumps to section 12,
`q` quits. `AUTO=1` advances on a timer and `TYPE=0` turns off the typewriter.

The pages fall into three groups:

| Pages | What they are |
|---|---|
| 0 | Clean-slate check — the fabric is in a known state before anything is claimed |
| 1-7 | **The story.** The host in Palette, what it is, its tags, the VLANs those tags name, the interface on the machine, the cluster, and where its traffic goes. Shared with `make demo-palette`. |
| 8-14 | **How it works.** The fabric, host-to-port binding, fail-closed behaviour, the host side, both halves together, the ComputePool path, and the fleet-scale bootstrap question. |
| 15-18 | Proven / not proven, delivery status, the two open disagreements, then teardown. |

This document covers the five pages that carry the technical argument - sections 8 to 12 - because
those are where a question can take you somewhere the screen does not go. The rest explains itself
on the page.

The "why" lines are the ones worth saying out loud. The commands are only evidence for them.

---

## Pre-flight (2 minutes, before anyone is watching)

```bash
cd ~/Desktop/nokia-eda-tenant-isolation
make verify          # transaction count now; compare it after the run
make demo            # or AUTO=1 TYPE=0 make demo for a silent dry pass
```

`make deps` names anything missing. The walkthrough finds the edge host itself - it tries `EDGE_IP`,
then `.work/edge-ip`, then libvirt - so a stale address is no longer something to check by hand.

Section 0 does the rest of the pre-flight on screen: it surveys the fabric, clears anything a
previous run left behind, and refuses to claim anything until the starting state is verified.

**If the fabric is down:** section 10 is entirely offline and still makes the strongest safety
argument on its own. `g 10` jumps straight to it.

---

## What each page does to the fabric

Most pages only read. These four write, and it is worth knowing which, because they are
the ones that take time and the ones a failure would leave state behind from.

| Page | Writes | Leaves behind |
|---|---|---|
| 0 | Deletes anything a previous run left | Nothing — that is its job |
| 4 | Creates `nokia-demo` + its bridge domain, binds `leaf1-ethernet-1-9` at VLAN 310 | The host's tenant, until page 18 |
| 8 | Clones that tenant into `nokia-neighbour` at the **same** gateway address | A second tenant, until page 18 |
| 9 | Nothing, when page 4 already holds the port | — |
| 18 | Deletes both, bridge interface → virtual network → bridge domain | Verified baseline |

Pages 4 and 8 each take roughly a minute, because they are genuinely driving the fabric
rather than describing it. That silence is expected; the driver prints as it goes.

**`lab-gpu-01` has exactly one cabled port.** Two attachments on it, even at the same VLAN,
fail the transaction and retry. This is why page 9 checks whether page 4 already holds the
port instead of binding it a second time, and why page 18 is not optional.

**Deletion order is load-bearing.** Always BridgeInterface → VirtualNetwork → BridgeDomain.
Delete a `VirtualNetwork` while one of its bridge interfaces still exists and the orphan
fails *every subsequent EDA transaction*, not just its own, while the fabric otherwise looks
healthy. `make clean` and page 18 both do it correctly; by hand, follow that order.

For what to say on each page, see [run-sheet.md](run-sheet.md) — this document is the
operational half, that one is the spoken half. [transcript.md](transcript.md) is a complete
recorded run, if you want to see the output without a fabric in front of you.

---

## Design rationale — answers to the questions that will come

**Why a first-class provider and not a content bundle?**
Isolation is established in cloud-init, before Kubernetes starts — the node and its CNI come up on a VLAN sub-interface of the isolated NIC. Bundle content is delivered only *after* a cluster is healthy, so it cannot participate in that phase at all. Isolation also has to be a product guarantee, not opt-in content.

**Why talk to EDA over the Kubernetes API?**
EDA's API *is* a Kubernetes API — `VirtualNetwork`, `BridgeDomain`, `BridgeInterface`, `TopoLink` are CRDs. There is no REST surface worth wrapping.

**Why one `VirtualNetwork` instead of composing Router + BridgeDomain?**
Its spec carries `routers` alongside `bridgeDomains` and `irbInterfaces`, and it emits thirteen child kinds. One object brings up the IP-VRF, MAC-VRF and IRBs together, lifecycle-bound. An earlier design composed them separately; the live CRD showed that was unnecessary.

**Why is readiness "an EVI was allocated" and not "operationalState is Up"?**
A unit with no pool attached sits at `Unknown` with zero sub-interfaces — a bridge domain only goes Up once something is bound to it. Gating on Up would leave every unit permanently not-ready until its first pool arrived. This was found by running against real hardware; it is not visible from the schema.

**How do you know the integration is correct?**
Every schema came from the live 26.4.3 API rather than the documentation, after the two disagreed in seven places. One with consequences: the bridge-domain status field is `numSubinterfaces`, not the plausible-looking `totalSubInterfaces` — we read a silent zero until it was checked against the cluster.

---

## If something breaks live

- **Fabric unreachable** → section 10 is fully offline and makes the strongest engineering argument on its own.
- **A page that writes hangs** → almost always two attachments on the one cabled port. Check
  `kubectl --context kind-eda-demo -n eda get bridgeinterfaces` for two rows on
  `leaf1-ethernet-1-9`, and the last few `transactionresults` for `Failed … retry`. Remove the
  one that is not `nokia-demo-*`, in dependency order.
- **Smoke test fails** → it needs `EDA_KUBECONFIG` and `EDA_FABRIC_NODE`; check those before
  blaming the fabric. `kubectl get bridgedomains` is the quick discriminator.
- **Numbers differ from this document** → expected and worth saying so. VNI/EVI are allocated per run by EDA. If they were identical every time, that would mean we were computing them, which is the bug we avoided.
- **Asked something you do not know** → "I would have to check" beats a guess in front of a vendor. Everything on pages 8 to 10 is reproducible on the spot.
