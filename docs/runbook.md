# EDA + PaletteAI — Live Demo Runbook

Four acts, **all four proven and safe to run live**. Acts 1–3 are fabric-side; Act 4 is the host side, verified 25 Aug 2026 on `lab-gpu-01` with stylus v4.9.39-rc.4.

Each act has: the setup, the commands, what to expect, and why it matters. The "why" lines are the ones worth saying out loud — the commands are just evidence for them.

---

## Pre-flight (2 minutes, before anyone is watching)

```bash
# 1. Is the fabric up?
kubectl --context kind-eda-demo -n eda get toponodes

# 2. Are both tenants still provisioned?
kubectl --context kind-eda-demo -n eda get bridgedomains

# 3. Is the repo ready to run tests?
cd ~/Desktop/nokia/mural/frisket
export GOPRIVATE='github.com/spectrocloud/*' GOTOOLCHAIN=go1.27.0 GOWORK=off
export EDA_KUBECONFIG=<path-to-eda.kubeconfig> EDA_FABRIC_NODE=lab-gpu-01
```

If step 2 shows `tenant-a-bd` and `tenant-b-bd` both `Up`, you have a demo.

**If the fabric is down:** skip to Act 3, which is entirely offline and still makes the strongest safety argument.

---

## Act 1 — The fabric, and what "isolated" actually means

**Rationale.** Nokia's audience will want to know we understand EVPN, not just that we called an API. This act shows we are provisioning real IP-VRF/MAC-VRF constructs and reading back the identifiers EDA allocated.

```bash
kubectl --context kind-eda-demo -n eda get toponodes
```

*Expect:* 2 leaves + 1 spine, `Connected` / `Synced`.

> "Three-node SR Linux fabric. Everything after this is against that, not a mock."

```bash
kubectl --context kind-eda-demo -n eda get bridgedomains
```

*Expect:*

```
NAME          VNI   EVI   IMPORT TARGET   EXPORT TARGET   TOTAL SUBIF   OPERATIONALSTATE
tenant-a-bd   200   100   target:1:100    target:1:100    3             Up
tenant-b-bd   201   101   target:1:101    target:1:101    2             Up
```

**The line to say:** *"Two tenants. Distinct VNI, distinct EVI, distinct route targets. We did not compute any of those — EDA's allocator did, and we read them back."*

### The punchline

```bash
for t in tenant-a tenant-b; do
  printf '%-10s ' "$t"
  kubectl --context kind-eda-demo -n eda get virtualnetwork $t \
    -o jsonpath='gateway={.spec.irbInterfaces[0].spec.ipAddresses[0].ipv4Address.ipPrefix} bd={.spec.irbInterfaces[0].spec.bridgeDomain}{"\n"}'
done
```

*Expect:* **both** tenants at `10.200.0.1/24`, on different bridge domains.

> "Same gateway address in both tenants. Overlapping address space, separated by EVPN. That is the property the whole feature exists to provide — and it is on the fabric right now, not on a slide."

**If asked "is traffic actually isolated?"** — answer straight: *the control plane is proven, the forwarding plane needs real endpoints, which needs `SIMULATE=false` and a licence.* Do not fudge this; it is the one claim we cannot make yet, and saying so buys credibility for everything else.

---

## Act 2 — A GPU host bound to a leaf port

**Rationale.** This is the part with no Aviz equivalent, and it is worth explaining *why* it was hard: EDA has no server-name-keyed API. Nothing answers "which port is host X on".

```bash
cd ~/Desktop/nokia/mural/frisket
go test -tags smoke ./internal/smoke/... -run TestReconcilersAgainstLiveCluster -v 2>&1 | grep -E "UNIT READY|BOUND|FABRIC CONFIRMS|PASS"
```

*Expect (numbers vary run to run — EDA allocates them):*

```
UNIT READY     origin=Managed bd=rc-smoke-bd vni=206 evi=106 rt=target:1:106
BOUND          host=edge-host-uid-1 node=lab-gpu-01 leaf=leaf1 iface=leaf1-ethernet-1-9 vlan=310 state=Up
FABRIC CONFIRMS subifs=1 down=0 nodes=1 state=Up
--- PASS: TestReconcilersAgainstLiveCluster
```

**Walk the three lines — this is the heart of the demo:**

1. **UNIT READY** — a tenant VPC created and realised. The VNI/EVI/RT came back from the fabric.
2. **BOUND** — we resolved a Palette host to a physical leaf port and attached it. We closed that mapping by reverse-indexing the Day-0 cabling intent: edge `TopoLink`s whose `remote.node` names the host.
3. **FABRIC CONFIRMS** — *"and this line is the bridge domain independently reporting the new sub-interface. That is the fabric agreeing with us, not us reporting our own write back to ourselves."*

That distinction is the one to land. EDA accepts a `BridgeInterface` long before the transaction programming it commits, so an API success proves nothing on its own.

---

## Act 3 — Fail-closed, and why it is the important part

**Rationale.** Tenant isolation fails in a specific and nasty way: a host that is *not* attached looks exactly like a healthy one. Nothing errors. This act shows we designed for that.

```bash
go test ./internal/controller/eda/... -v 2>&1 | grep -E "^    --- PASS" | sed 's/^    --- //'
```

*Point at these four:*

```
PASS: host_with_no_fabric_node_fails_the_whole_request_and_writes_nothing
PASS: fabric_node_matching_no_topolink_is_unmapped
PASS: two_hosts_claiming_one_port_fails_without_writing
PASS: Attached_only_once_every_binding_is_operational
```

> "If any host in a pool cannot be resolved, we fail the entire request and write *nothing* to the fabric. Attaching the ones we could resolve would leave the pool partly isolated while reporting success. The test asserts the fabric is untouched afterwards — it is not just a return code."

**Worth mentioning if there is appetite:** a multi-rail host must have *every* rail bound. Missing one is a real data-plane leak that nothing downstream would catch.

### Optional: prove the tests have teeth

If someone is sceptical that green tests mean anything:

> "Each of those was verified by removing the behaviour and confirming the test fails. Dropping the fail-closed guard, gating readiness on the write succeeding, and skipping the shrink pass all break the suite."

---

## Act 4 — Host-side VLAN

**Status: proven** on 25 Aug 2026, edge host `lab-gpu-01` (`192.168.122.171`), stylus agent-mode **v4.9.39-rc.4**.

**Rationale.** Acts 1–3 are all fabric-side. This is the other half: a host tagged through Palette bringing up the matching tenant interface by itself.

```bash
sshpass -p demo ssh demo@192.168.122.171 'ip -d link show enp2s0.310; ip -brief addr show enp2s0.310'
```

*Expect:*

```
enp2s0.310@enp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP
    vlan protocol 802.1Q id 310 <REORDER_HDR>
enp2s0.310@enp2s0  UP  10.210.0.50/24
```

> "Nobody configured that interface. The host carries five `net-iso-*` tags in Palette. The agent read them and created an 802.1Q sub-interface, VLAN 310, at 10.210.0.50/24 — the exact values in the tags — on a NIC that had no address at all."

### The punchline — and the strongest slide in the deck

```bash
sshpass -p demo ssh demo@192.168.122.171 \
  'sudo grep -o "\"node-ip\":\[[^]]*\]" /etc/rancher/k3s/config.yaml.d/*.yaml | head -1'
```

*Expect:* `"node-ip":["10.210.0.50"]`

> "Kubernetes is coming up **on the isolated VLAN address**, not the management IP. That is the entire architectural argument in one line: isolation is established before Kubernetes starts. A profile bundle is delivered only after a cluster is already healthy, so it could never do this."

**Reproducing it.** The one non-obvious step is `stylus.skipStylusUpgrade: true` in the edge-host userdata, as a **sibling of `site:`**, not inside it. Without it the agent reconciles its own version down to whatever the Palette instance declares (4.8.20 here), which predates the `net-iso-*` tags and ignores them silently. The VIP must also sit inside the tenant CIDR — the agent fail-closes with `invalid vip ... is not in the CIDR 10.210.0.50/24`, which is worth showing if anyone doubts the tags are really being read.

**If the interface is not up,** say: *"The fabric half programs the leaf port — you have just seen it. The host half is verified separately."* That is still true and beats a failed live command.

---

## Act 5 — Both halves, at the same time

**Status: proven** 25 Aug 2026. This is the closing shot: the *same VLAN* on the leaf port and on the host cabled to it, each put there by a different half of the system.

```bash
# Fabric side — the provider programmed the leaf port
kubectl --context kind-eda-demo -n eda get bridgeinterface nokia-demo-pool-leaf1-ethernet-1-9 \
  -o jsonpath='{.spec.interface} vlan={.spec.vlanID} bd={.spec.bridgeDomain}{"\n"}'

# Host side — stylus raised the matching interface from its Palette tags
sshpass -p demo ssh demo@192.168.122.171 'ip -brief addr show enp2s0.310'
```

*Expect:*

```
leaf1-ethernet-1-9 vlan=310 bd=nokia-demo-bd
enp2s0.310@enp2s0  UP  10.210.0.50/24
```

> "Left: the fabric. We resolved this GPU host to a physical leaf port and put VLAN 310 on it, in a bridge domain with its own VNI, EVI and route target. Right: the host. Nobody logged in — the agent read five tags from Palette and raised the matching 802.1Q interface, inside that subnet, on a NIC that had no address at all."
>
> "Neither half knows about the other. They agree because they were both derived from the same intent."

Worth adding, because it is the part that could not be done any other way:

```bash
sshpass -p demo ssh demo@192.168.122.171 \
  'sudo grep -o "\"node-ip\":\[[^]]*\]" /etc/rancher/k3s/config.yaml.d/*.yaml | head -1'
```

> "And Kubernetes came up *on* that isolated address. Not the management IP. That is why this has to be a provider and not bundle content — content is delivered after a cluster is healthy, and by then this decision is long made."

**The honest boundary.** This is control-plane and host-configuration proof. It does not yet demonstrate that traffic cannot cross between tenants — that needs `SIMULATE=false` and a licence. Say so before being asked.

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

- **Fabric unreachable** → Act 3 is fully offline and makes the strongest engineering argument on its own.
- **Smoke test fails** → it needs `EDA_KUBECONFIG` and `EDA_FABRIC_NODE`; check those before blaming the fabric. `kubectl get bridgedomains` is the quick discriminator.
- **Numbers differ from this document** → expected and worth saying so. VNI/EVI are allocated per run by EDA. If they were identical every time, that would mean we were computing them, which is the bug we avoided.
- **Asked something you do not know** → "I would have to check" beats a guess in front of a vendor. Everything in Acts 1–3 is reproducible on the spot.
