#!/usr/bin/env bash
# =============================================================================
# build-edge-host.sh — build a Palette edge host with fabric-isolation tags,
# from nothing to a live tenant VLAN, in roughly four minutes.
#
# Creates a local KVM guest, installs the Palette edge agent, registers it
# against Palette with the net-iso-* tags in place, deploys a single-node
# cluster, and waits for the tenant VLAN sub-interface to come up.
#
# Every lesson from the failed attempts is applied up front rather than
# discovered. In particular:
#
#   * stylus.skipStylusUpgrade must be a SIBLING of site:, not inside it.
#     Without it the agent reconciles its own version down to whatever the
#     Palette instance declares — which may predate the net-iso-* tags and
#     will ignore them silently.
#   * The net-iso-* tags must exist BEFORE first registration. They are
#     snapshotted at registration and never re-read.
#   * Size the VM correctly at creation. Resizing mid-deploy corrupts the
#     kine datastore and crash-loops k3s.
#   * Run the installer BEFORE pinning anything. It rsyncs into
#     /opt/spectrocloud/bin and an immutable file makes it fail with exit 23.
#   * The control-plane VIP must sit INSIDE the tenant CIDR. The agent
#     fail-closes otherwise:
#         invalid vip … is not in the CIDR <subnet>
#
# Configuration comes from .env — copy .env.example and fill it in.
# No credential is stored in this repository.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

need(){ [ -n "${!1:-}" ] || { echo "missing required setting: $1  (see .env.example)"; exit 1; }; }
for v in PALETTE_ENDPOINT PALETTE_API_KEY PALETTE_PROJECT_UID \
         EDGE_REGISTRATION_TOKEN CLUSTER_PROFILE_UID; do need "$v"; done

: "${VM_NAME:=eda-edge-01}"
: "${EDGE_HOST_NAME:=lab-gpu-01}"
: "${NET_ISO_INTERFACE:=enp2s0}"
: "${NET_ISO_VLAN:=310}"
: "${NET_ISO_SUBNET_IPV4:=10.210.0.50}"
: "${NET_ISO_SUBNET_PREFIX:=24}"
: "${CONTROL_PLANE_VIP:=10.210.0.100}"
: "${VM_MEMORY_MB:=8192}"
: "${VM_VCPUS:=4}"
: "${VM_DISK_GB:=40}"
# libvirt connection. The system instance is the default because session mode has
# no networks of its own — `--network network=default` only exists under
# qemu:///system — and because /var/lib/libvirt/images is root-owned, so
# virt-install must run privileged to open it as a storage pool.
: "${LIBVIRT_URI:=qemu:///system}"
: "${LIBVIRT_IMAGES:=/var/lib/libvirt/images}"
# Privileged only when targeting the system instance; a session URI needs no sudo.
case "$LIBVIRT_URI" in
  *system*) VIRT_SUDO="sudo" ;;
  *)        VIRT_SUDO="" ;;
esac
VIRSH(){ $VIRT_SUDO virsh -c "$LIBVIRT_URI" "$@"; }
: "${AGENT_TAR:=$ROOT/.artifacts/agent-mode-linux-amd64.tar}"
: "${WORKDIR:=$ROOT/.work}"

mkdir -p "$WORKDIR"

T0=$(date +%s); phase_start=$T0
log()   { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
phase() { local now; now=$(date +%s); printf '[%s] === %s === (prev %ss, total %ss)\n' \
          "$(date +%H:%M:%S)" "$1" "$((now-phase_start))" "$((now-T0))"; phase_start=$now; }
die()   { log "FAILED: $*"; log "elapsed: $(($(date +%s)-T0))s"; exit 1; }
api()   { curl -sk -H "ApiKey: $PALETTE_API_KEY" -H "ProjectUid: $PALETTE_PROJECT_UID" "$@"; }
SSH()   { sshpass -p "${VM_PASSWORD:-demo}" ssh -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
          "${VM_USER:-demo}@$IP" "$@"; }

# ----------------------------------------------------------------- 1. image
phase "base image"
[ -f "$AGENT_TAR" ] || die "agent tarball not found at $AGENT_TAR — run 'make agent' first"
cd "$WORKDIR" || die "workdir"
if [ ! -f noble.img ]; then
  log "downloading Ubuntu Noble cloud image"
  timeout 900 curl -sSL -o noble.img \
    https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img || die "download"
fi

# cloud-init seed for the base VM (not the Palette userdata — that comes later)
cat > meta-data <<EOF
instance-id: $VM_NAME
local-hostname: $EDGE_HOST_NAME
EOF
cat > user-data <<EOF
#cloud-config
hostname: $EDGE_HOST_NAME
users:
  - name: ${VM_USER:-demo}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${VM_PASSWORD:-demo}
ssh_pwauth: true
chpasswd: {expire: false}
package_update: true
packages: [bash, jq, zstd, rsync, systemd-timesyncd, conntrack, iptables, rsyslog, vlan]
write_files:
  # The k3s pack hardens the API server with audit logging and asks the kubelet
  # to enforce protect-kernel-defaults. Both are host prerequisites, and neither
  # is created by the pack: without them k3s starts, fails, and leaves a cluster
  # that looks like it is still coming up. Cost four wrong diagnoses once.
  - path: /etc/kubernetes/audit-policy.yaml
    permissions: "0644"
    content: |
      apiVersion: audit.k8s.io/v1
      kind: Policy
      rules:
        - level: Metadata
  # protect-kernel-defaults=true makes the kubelet refuse to start unless these
  # already hold. It will not set them itself.
  - path: /etc/sysctl.d/90-kubelet.conf
    permissions: "0644"
    content: |
      kernel.panic = 10
      kernel.panic_on_oops = 1
      vm.overcommit_memory = 1
      vm.panic_on_oom = 0
runcmd:
  - systemctl enable --now systemd-timesyncd
  - systemctl enable --now systemd-networkd
  - sysctl --system
EOF
cloud-localds seed.iso user-data meta-data || die "cloud-localds"

# -------------------------------------------------------------------- 2. VM
phase "create VM"
# Release the host before deleting it. Palette refuses to remove an edge host that
# is still attached to a cluster, and because that DELETE used to be fired blind the
# failure surfaced much later as the agent looping on
#   "edge device with uid ... already exists. Delete the device from Palette"
# which points at the wrong thing entirely.
for c in $(api "$PALETTE_ENDPOINT/v1/spectroclusters?limit=100" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
want='${CLUSTER_NAME:-eda-iso-demo}'
for i in d.get('items',[]):
    if i.get('metadata',{}).get('name')==want and i.get('status',{}).get('state')!='Deleted':
        print(i['metadata']['uid'])" 2>/dev/null); do
  log "releasing the host from an existing cluster ($c)"
  api -X DELETE "$PALETTE_ENDPOINT/v1/spectroclusters/$c" >/dev/null 2>&1
  # A cluster that never finished provisioning can sit in Deleting indefinitely and
  # keeps the edge host in inUseClusters, which blocks the host delete. forceDelete
  # clears it, but Palette only accepts it once the cluster is already in Deleting —
  # hence the ordinary delete first, then this.
  forced=0
  for i in $(seq 1 42); do
    st=$(api "$PALETTE_ENDPOINT/v1/spectroclusters/$c" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('status',{}).get('state','GONE'))
except Exception: print('GONE')" 2>/dev/null)
    case "$st" in Deleted|GONE) break ;; esac
    if [ "$st" = "Deleting" ] && [ "$forced" = 0 ] && [ "$i" -ge 6 ]; then
      log "  cluster still Deleting after 60s — forcing"
      api -X DELETE "$PALETTE_ENDPOINT/v1/spectroclusters/$c?forceDelete=true" >/dev/null 2>&1
      forced=1
    fi
    sleep 10
  done
done

code=$(api -X DELETE -o /dev/null -w '%{http_code}' "$PALETTE_ENDPOINT/v1/edgehosts/$EDGE_HOST_NAME" 2>/dev/null)
case "$code" in
  200|204|404) log "edge host record clear (HTTP $code)" ;;
  *) die "could not remove the existing '$EDGE_HOST_NAME' edge host (HTTP $code) — it is
        probably still attached to a cluster. Remove that cluster in Palette, then retry." ;;
esac

VIRSH destroy "$VM_NAME" >/dev/null 2>&1
VIRSH undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1
rm -f "${VM_NAME}.qcow2"

qemu-img convert -O qcow2 noble.img "${VM_NAME}.qcow2"        || die "convert"
qemu-img resize "${VM_NAME}.qcow2" "${VM_DISK_GB}G" >/dev/null 2>&1 || die "resize"
sudo cp "${VM_NAME}.qcow2" "$LIBVIRT_IMAGES/${VM_NAME}.qcow2" || die "copy disk"
sudo cp seed.iso "$LIBVIRT_IMAGES/${VM_NAME}-seed.iso"        || die "copy seed"
sudo chown libvirt-qemu:kvm "$LIBVIRT_IMAGES/${VM_NAME}.qcow2" "$LIBVIRT_IMAGES/${VM_NAME}-seed.iso"

# Two NICs: management, plus the fabric-facing NIC the tags name.
$VIRT_SUDO virt-install --connect "$LIBVIRT_URI" \
  --name "$VM_NAME" --memory "$VM_MEMORY_MB" --vcpus "$VM_VCPUS" \
  --disk "path=$LIBVIRT_IMAGES/${VM_NAME}.qcow2,format=qcow2,bus=virtio" \
  --disk "path=$LIBVIRT_IMAGES/${VM_NAME}-seed.iso,device=cdrom" \
  --network "network=${LIBVIRT_NETWORK:-default},model=virtio" \
  --network "network=${LIBVIRT_NETWORK:-default},model=virtio" \
  --os-variant ubuntu24.04 --graphics none --noautoconsole --import 2>&1 | sed 's/^/    /' \
  || true
VIRSH dominfo "$VM_NAME" >/dev/null 2>&1 \
  || die "virt-install did not create $VM_NAME (see the error above). If it is a permissions
        or network error, check LIBVIRT_URI=$LIBVIRT_URI — session mode has no 'default'
        network and cannot read $LIBVIRT_IMAGES."

IP=""
for _ in $(seq 1 60); do
  IP=$(VIRSH domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$IP" ] && break
  sleep 5
done
[ -n "$IP" ] || die "VM never obtained an address"
log "VM up at $IP"
for _ in $(seq 1 60); do SSH true >/dev/null 2>&1 && break; sleep 5; done
SSH true >/dev/null 2>&1 || die "ssh never came up"
SSH 'cloud-init status --wait' >/dev/null 2>&1
log "cloud-init complete"

# ------------------------------------------------------- 3. agent + userdata
phase "install agent"
sshpass -p "${VM_PASSWORD:-demo}" scp -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "$AGENT_TAR" "${VM_USER:-demo}@$IP":/tmp/agent.tar >/dev/null 2>&1 || die "scp agent"
SSH 'sudo tar -xf /tmp/agent.tar -C /' || die "extract agent"

SSH "sudo mkdir -p /var/lib/spectro && sudo tee /var/lib/spectro/userdata >/dev/null <<'EOF'
#cloud-config
stylus:
  skipStylusUpgrade: true
  site:
    edgeHostToken: $EDGE_REGISTRATION_TOKEN
    paletteEndpoint: ${PALETTE_ENDPOINT#https://}
    name: $EDGE_HOST_NAME
    projectName: ${PALETTE_PROJECT_NAME:-Default}
    insecureSkipVerify: true
    tags:
      net-iso-provider: eda
      net-iso-interface: $NET_ISO_INTERFACE
      net-iso-vlan: \"$NET_ISO_VLAN\"
      net-iso-subnet-ipv4: $NET_ISO_SUBNET_IPV4
      net-iso-subnet-prefix-length: \"$NET_ISO_SUBNET_PREFIX\"
install:
  poweroff: false
EOF" || die "write userdata"
log "userdata written: $(SSH 'grep -c net-iso /var/lib/spectro/userdata') tags + skipStylusUpgrade"

# ------------------------------------------------------------ 4. registration
phase "register"
SSH 'sudo bash /var/lib/spectro/spectro-init.sh' >/dev/null 2>&1
registered=0
for _ in $(seq 1 60); do
  st=$(api "$PALETTE_ENDPOINT/v1/edgehosts/$EDGE_HOST_NAME" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('status',{}).get('health',{}).get('state',''))
except Exception: print('')" 2>/dev/null)
  [ "$st" = "healthy" ] && { registered=1; break; }
  sleep 10
done
[ "$registered" = 1 ] || die "host never registered"
log "registered healthy"
log "agent version: $(SSH 'sudo journalctl -u spectro-stylus-agent --no-pager --since "-3 min" 2>/dev/null | grep -oE "version=v[0-9]+\.[0-9]+\.[0-9.rc-]+" | sort -u | tr "\n" " "')"
api "$PALETTE_ENDPOINT/v1/edgehosts/$EDGE_HOST_NAME" 2>/dev/null | python3 -c "
import json,sys
l=json.load(sys.stdin).get('metadata',{}).get('labels') or {}
print('    net-iso labels in Palette:', len([k for k in l if k.startswith('net-iso')]))" 2>/dev/null

# ---------------------------------------------------------------- 5. cluster
phase "deploy cluster"
python3 - "$CLUSTER_PROFILE_UID" "$CONTROL_PLANE_VIP" "$EDGE_HOST_NAME" \
  "${CLUSTER_NAME:-eda-iso-demo}" "${PROFILE_VARIABLES:-}" <<'PY' > "$WORKDIR/cluster.json"
import json,sys
prof,vip,uid,name,rawvars=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5]
variables=[]
for pair in filter(None, rawvars.split(",")):
    k,_,v=pair.partition("=")
    variables.append({"name":k.strip(),"value":v.strip()})
print(json.dumps({
 "metadata":{"name":name,"labels":{}},
 "spec":{"cloudType":"edge-native",
  "profiles":[{"uid":prof,"variables":variables}],
  "cloudConfig":{"controlPlaneEndpoint":{"host":vip,"type":"IP"}},
  "machinePoolConfig":[{"cloudConfig":{"edgeHosts":[{"hostUid":uid}]},
   "poolConfig":{"name":"cp-pool","isControlPlane":True,
                 "labels":["control-plane"],"size":1}}]}}))
PY
# A cluster of this name may survive an earlier run. Palette rejects a duplicate
# name outright, so clear it first — otherwise every run after the first fails.
OLD=$(api "$PALETTE_ENDPOINT/v1/spectroclusters?limit=100" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for i in d.get('items',[]):
    m=i.get('metadata',{})
    if m.get('name')=='${CLUSTER_NAME:-eda-iso-demo}' and (i.get('status',{}).get('state') != 'Deleted'):
        print(m.get('uid'))" 2>/dev/null)
for c in $OLD; do
  log "removing an existing '${CLUSTER_NAME:-eda-iso-demo}' cluster ($c)"
  api -X DELETE "$PALETTE_ENDPOINT/v1/spectroclusters/$c" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    st=$(api "$PALETTE_ENDPOINT/v1/spectroclusters/$c" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('status',{}).get('state','GONE'))
except Exception: print('GONE')" 2>/dev/null)
    case "$st" in Deleted|GONE) break ;; esac
    sleep 10
  done
done

RESP=$(api -X POST -H 'Content-Type: application/json' -d @"$WORKDIR/cluster.json" \
       "$PALETTE_ENDPOINT/v1/spectroclusters/edge-native" 2>/dev/null)
CID=$(printf '%s' "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin).get('uid',''))" 2>/dev/null)
if [ -z "$CID" ]; then
  log "Palette rejected the cluster request:"
  printf '%s\n' "$RESP" | head -c 500 | sed 's/^/    /'
  die "cluster not created"
fi
log "cluster $CID"
echo "$CID" > "$WORKDIR/cluster-id"

# ------------------------------------------------------------------ 6. VLAN
phase "wait for the tenant VLAN"
IFACE="$NET_ISO_INTERFACE.$NET_ISO_VLAN"
up=0
for i in $(seq 1 120); do
  vlan=$(SSH "ip -brief addr show $IFACE 2>/dev/null" 2>/dev/null)
  if [ -n "$vlan" ]; then up=1; log "VLAN UP: $vlan"; break; fi
  if [ $((i % 6)) -eq 1 ]; then
    verr=$(SSH 'sudo journalctl --no-pager --since "-3 min" 2>/dev/null | grep -c "invalid vip"' 2>/dev/null)
    log "  waiting… vip-errors=${verr:-0}"
  fi
  sleep 15
done
[ "$up" = 1 ] || die "VLAN never appeared — check 'journalctl | grep -i isolat' on $IP"

phase "edge host ready"
log "TOTAL: $(($(date +%s)-T0))s"
echo "$IP" > "$WORKDIR/edge-ip"
log "export EDGE_IP=$IP  before running scripts/demo-record.sh"
