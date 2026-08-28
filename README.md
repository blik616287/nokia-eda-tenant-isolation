# Nokia EDA tenant isolation

Fabric-level tenant isolation for Palette-managed GPU hosts, demonstrated end to end against a
live Nokia EDA fabric.

Two tenants carry **overlapping IP space** and are separated by EVPN. A GPU host is resolved to its
physical leaf port and bound into its tenant's bridge domain. The same host raises the matching VLAN
sub-interface from tags — and Kubernetes comes up *on that isolated address*, not the management one.

Everything here runs live. Nothing is mocked, and nothing is replayed from a recording.

```
+================================+            +================================+
| EDA FABRIC — Nokia SR Linux    |            | PALETTE EDGE HOST              |
| leaf1 / leaf2  7220 IXR-D3L    |  <======>  | lab-gpu-01                     |
| spine1         7220 IXR-D5     |  VLAN 310  | enp2s0  ->  enp2s0.310         |
| tenant bridge domains (EVPN)   |  <======>  | 10.210.0.50/24                 |
+================================+            +================================+
```

Neither half reads the other. They agree because both derive from the same declared intent.

---

## Quick start

```bash
cp .env.example .env      # then fill it in — see "Configuration" below
make profile              # create + publish the three-pack cluster profile
make deps                 # names anything missing
make agent                # download + checksum the pinned edge-agent build
make host                 # build the edge host from nothing  (~4½ minutes)
make demo                 # the walkthrough, against the live fabric
```

Each demo is paginated — one section per page. `enter` advances, `p` goes back, `r` replays the
current page, `g 5` jumps to section 5, `q` quits. `AUTO=1` advances on a timer, `TYPE=0` turns off
the typewriter.

Three cuts of the same evidence, all live against the same environment:

| Target | What it is |
|---|---|
| `make demo` | Eighteen pages: the story, then how it works, then what is open. |
| `make demo-tyler` | The same sections in a shorter order, led by the ComputePool path. |
| `make demo-palette` | The story alone — pages 1–7 — for a Palette-weighted room. |
| `make demo-bootstrap` | Section 14 on its own: who writes a host's configuration at fleet scale. |

Tear down with `make clean` (fabric state) or `make destroy` (also removes the VM and its Palette
records).

### The edge host's management address moves

The VM's management address is a DHCP lease: it changes on every reboot, not only on every rebuild.
The walkthroughs handle this themselves — each one tries `EDGE_IP`, then `.work/edge-ip`, then asks
libvirt, and prints which address answered:

```
edge host is at 192.168.122.206, not 192.168.122.178 — using the address that answers
```

The libvirt lookup uses `sudo -n`, so it can never sit waiting for a password mid-demo; if sudo is
unavailable it simply falls through. You should not need to export `EDGE_IP` at all, but it still
wins if you set it and the host answers there.

Only the *management* address moves. The tenant address is fixed by the isolation tags, so
`enp2s0.310` stays at `10.210.0.50/24` throughout — if that one changes, something is genuinely
wrong.

## What you need

- A reachable **Nokia EDA** fabric. Developed against EDA 26.4.3 (Digital Twin) with SR Linux 26.3.1
  — two leaves and a spine.
- A **Palette** instance, a project, an edge registration token, and an edge-native cluster profile
  with exactly three packs:

  | Layer | Pack | Version |
  |---|---|---|
  | os | `edge-native-byoi` | 2.1.0 |
  | k8s | `edge-k3s` | 1.35.3 |
  | cni | `cni-calico` | 3.32.0 |

  `make profile` builds exactly that and publishes it; the k3s values live in
  `profile/edge-k3s.values.yaml` so the profile is reproducible rather than clicked together.
  The `packUid`/`registryUid` in `profile/profile.json` are specific to our Palette instance —
  override them in `.env`, and `scripts/create-profile.sh` documents how to read yours off any
  existing edge-native profile.

  Nothing else. Addons are not just unnecessary here, they actively fail: a single-node edge cluster's
  only node is the control plane and carries `node-role.kubernetes.io/control-plane:NoSchedule`, so
  any pack whose chart has no toleration for it sits `Pending` forever. Removing the taint by hand
  does not help — the stylus operator re-applies it on a ~2-minute reconcile. Either give the addon a
  toleration or leave it out.
- **libvirt/KVM** locally. The edge host is a local VM with two NICs: management, plus the
  fabric-facing NIC the isolation tags name.
- The **edge-agent build**, fetched by `make agent`. It is SpectroCloud proprietary and is *not*
  redistributed here — it is served from Artifactory to a read-only, scoped, expiring token issued
  separately. `make agent` verifies its SHA-256 before use.
- One **cabled edge `TopoLink`** whose `remote.node` names your host. That mapping is how the
  provider finds the leaf port; without it, resolution fails closed and nothing is written.

## Configuration

Everything lives in `.env`, which is gitignored. `.env.example` documents every setting. Two are
easy to get wrong and both fail in ways worth knowing:

- **`CONTROL_PLANE_VIP` must sit inside the tenant subnet.** The agent refuses to deploy otherwise —
  `invalid vip … is not in the CIDR …`. That refusal is the isolation contract being enforced, and
  it is also a useful signal that the tags were genuinely parsed rather than merely accepted.
- **`EDA_FABRIC_NODE` must match the `remote.node`** on the edge `TopoLink` for your host.

The k3s pack ships hardened API-server and kubelet flags that depend on two files existing on the
host *before* k3s starts — `/etc/kubernetes/audit-policy.yaml`, and the sysctls that
`protect-kernel-defaults=true` refuses to start without. The pack does not create either. `make host`
writes both from cloud-init; if you build the host another way, create them yourself, because k3s
fails in a way that looks like a cluster still coming up.

## What each part does

| Path | Purpose |
|---|---|
| `scripts/demo-record.sh` | The walkthrough. Eighteen pages, live against the fabric, tears its own state down. |
| `scripts/beats-palette.sh` | Pages 1–7 and the shared helpers, sourced by both walkthroughs so they cannot drift. |
| `scripts/demo-palette.sh` | `make demo-palette` — the story on its own, ten pages, for a Palette-weighted room. |
| `scripts/demo-bootstrap.sh` | The bootstrap dependency: a host boots knowing only its MAC and is served its isolation values. |
| `scripts/provision-endpoint.py` | Derives those values live from the fabric. Fails closed when the address does not fit the tenant. |
| `scripts/build-edge-host.sh` | Edge host from nothing to a live tenant VLAN, ~4½ min, timed per phase. |
| `profile/` | The cluster profile: three packs, and the k3s values that make them work. |
| `scripts/create-profile.sh` | Builds and publishes that profile against your Palette instance. |
| `scripts/fetch-agent.sh` | Pulls and verifies the pinned agent build. |
| `testdata/act5-driver.gotest` | Drives the provider's reconcilers so fabric state persists for the side-by-side comparison. |
| `docs/companion.md` | Written for Nokia EDA engineers: architecture, findings, and the ask. |
| `docs/run-sheet.md` | One or two sentences to say per page, for presenting at pace. |
| `docs/runbook.md` | Rationale, expected output, and what to say when something is not up. |
| `docs/verification-summary.md` | Two-page summary of what was verified and how. |

## Reproducing it honestly

Two things in here exist specifically so the demo cannot lie about itself, and both are worth
understanding before you trust a green run.

**Go replays cached test results byte-for-byte** — including the `t.Logf` evidence lines and the
original duration. A cached `PASS` is indistinguishable from a live run on screen. Every `go test`
therefore runs with `-count=1`, and the real proof of liveness is the **EDA transaction delta**: a
live walkthrough moves the counter by about 8. Zero means nothing ran, whatever the output said.

```bash
make verify        # before and after `make demo`
```

**Deletion order on the fabric is load-bearing.** Always
**BridgeInterface → VirtualNetwork → BridgeDomain**. Delete a `VirtualNetwork` while one of its
`BridgeInterface`s still exists and the orphan yields `missing dependency of type BridgeDomain` on
*every subsequent EDA transaction* — not just its own — until it is removed by hand, while the fabric
otherwise looks healthy. `make clean` and the demo's own teardown both do this correctly; if you
delete by hand, do it in that order.

## What is proven, and what is not

| Claim | Status |
|---|---|
| EVPN tenancy with overlapping address space; distinct VNI / EVI / RT | **Proven** |
| Host resolved to its physical leaf port and attached | **Proven** — the fabric independently confirms the sub-interface |
| Fail-closed on unresolvable hosts, duplicate ports, partial binds | **Proven** — each test verified to fail when the behaviour is removed |
| Host raises the matching VLAN from tags | **Proven** |
| Kubernetes runs on the isolated address | **Proven** |
| **Traffic cannot cross between tenants** | **Not proven** — needs `SIMULATE=false` and a licence |
| Multi-rail hosts; pool scaling on real hardware | **Not proven** — needs hardware |

The last two are stated plainly because the first five are stronger for it. See `docs/companion.md`
§6 for the detail, and §1 for what we are asking Nokia to confirm.

## Security

No credential is committed here. `.env`, `*.kubeconfig` and `.jfrog-*` are gitignored.

The artifact token is **read-only, scoped to a single repository, and expires**. It cannot write,
cannot delete, and cannot see any other repository. If yours has lapsed, ask for a new one rather
than a broader one.

## Licence and attribution

The demo scripts and documentation in this repository are provided for evaluation. The Palette edge
agent fetched by `make agent` is SpectroCloud proprietary software, is not redistributed here, and
remains subject to its own terms.
