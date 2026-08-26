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
: "${LIBVIRT_IMAGES:=/var/lib/libvirt/images}"
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
runcmd:
  - systemctl enable --now systemd-timesyncd
  - systemctl enable --now systemd-networkd
EOF
cloud-localds seed.iso user-data meta-data || die "cloud-localds"

# -------------------------------------------------------------------- 2. VM
phase "create VM"
api -X DELETE "$PALETTE_ENDPOINT/v1/edgehosts/$EDGE_HOST_NAME" >/dev/null 2>&1
virsh destroy "$VM_NAME" >/dev/null 2>&1
virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1
rm -f "${VM_NAME}.qcow2"

qemu-img convert -O qcow2 noble.img "${VM_NAME}.qcow2"        || die "convert"
qemu-img resize "${VM_NAME}.qcow2" "${VM_DISK_GB}G" >/dev/null 2>&1 || die "resize"
sudo cp "${VM_NAME}.qcow2" "$LIBVIRT_IMAGES/${VM_NAME}.qcow2" || die "copy disk"
sudo cp seed.iso "$LIBVIRT_IMAGES/${VM_NAME}-seed.iso"        || die "copy seed"
sudo chown libvirt-qemu:kvm "$LIBVIRT_IMAGES/${VM_NAME}.qcow2" "$LIBVIRT_IMAGES/${VM_NAME}-seed.iso"

# Two NICs: management, plus the fabric-facing NIC the tags name.
virt-install --name "$VM_NAME" --memory "$VM_MEMORY_MB" --vcpus "$VM_VCPUS" \
  --disk "path=$LIBVIRT_IMAGES/${VM_NAME}.qcow2,format=qcow2,bus=virtio" \
  --disk "path=$LIBVIRT_IMAGES/${VM_NAME}-seed.iso,device=cdrom" \
  --network "network=${LIBVIRT_NETWORK:-default},model=virtio" \
  --network "network=${LIBVIRT_NETWORK:-default},model=virtio" \
  --os-variant ubuntu24.04 --graphics none --noautoconsole --import >/dev/null 2>&1 \
  || die "virt-install"

IP=""
for _ in $(seq 1 60); do
  IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
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
CID=$(api -X POST -H 'Content-Type: application/json' -d @"$WORKDIR/cluster.json" \
      "$PALETTE_ENDPOINT/v1/spectroclusters/edge-native" 2>/dev/null \
      | python3 -c "import json,sys;print(json.load(sys.stdin).get('uid',''))" 2>/dev/null)
[ -n "$CID" ] || die "cluster not created — check CLUSTER_PROFILE_UID and PROFILE_VARIABLES"
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
