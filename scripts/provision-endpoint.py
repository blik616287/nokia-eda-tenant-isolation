#!/usr/bin/env python3
"""
provision-endpoint.py — the boot-time half of the bootstrap problem, emulated.

WHAT PROBLEM THIS IS FOR
    Configuring a host's primary interface from a controller the host reaches
    OVER that interface is circular. The demo avoids it by having the isolation
    values already present in /var/lib/spectro/userdata before the agent starts.
    Today that file is written by hand, over SSH, which is fine for one host and
    is exactly the thing that does not survive contact with a fleet.

    This is what writes it instead: a host boots knowing only its own identity,
    asks for its configuration over the provisioning network, and is told which
    tenant it belongs to and how to bring up the interface. No per-host file is
    authored anywhere. Every machine boots the same image.

WHAT IS REAL HERE AND WHAT IS NOT
    Real   the derivation. Pool assignment -> tenant -> the tenant's actual VLAN
           and subnet, read live from EDA, not from a table. Run it against the
           fabric and the answer changes when the fabric changes.
    Real   the output. Compares byte-for-byte against the net-iso block on the
           running host -- see demo-bootstrap.sh, which diffs the two.
    Not    the transport. A production host gets this over PXE/iPXE or from an
           out-of-band installer. Here it is plain HTTP on the management
           network, which is the same shape and none of the same work.
    Not    the identity. Production keys on the DHCP relay's Option 82
           circuit-id -- the leaf inserts the port the request arrived on, so
           nothing has to look the host up at all. The Digital Twin has no
           forwarding plane, so there is no relay to insert it; we key on MAC
           from inventory instead. Do not present the circuit-id path as shown.

USAGE
    ./provision-endpoint.py --once 52:54:00:26:9a:5e      # print, don't serve
    ./provision-endpoint.py --once <mac> --explain        # show the derivation
    ./provision-endpoint.py --once <mac> --tenant tenant-a  # prove it is live, not a table
    ./provision-endpoint.py --serve 8080                  # GET /userdata?mac=..
"""
import json, os, subprocess, sys, ipaddress
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KCTX = os.environ.get("KCTX", "kind-eda-demo")
NS   = os.environ.get("NS", "eda")


def kube(kind, name=None):
    cmd = ["kubectl", "--context", KCTX, "-n", NS, "get", kind]
    if name:
        cmd.append(name)
    cmd += ["-o", "json"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise LookupError(f"{kind}{'/' + name if name else ''}: {p.stderr.strip().splitlines()[-1:]}")
    return json.loads(p.stdout)


def assignments():
    with open(os.path.join(ROOT, "provisioning", "assignments.json")) as f:
        return json.load(f)


def leaf_port(host):
    """The Day-0 cabling record, read backwards. RFC-0021 4e replaces this with
    the port carried on the host record; the rest of the derivation is unchanged
    either way, which is why it is worth separating out."""
    for item in kube("topolinks").get("items", []):
        for link in item["spec"].get("links", []):
            if link.get("type") == "edge" and (link.get("remote") or {}).get("node") == host:
                return link["local"]["node"], link["local"]["interfaceResource"]
    return None, None


def tenant_subnet(tenant):
    """The tenant's own addressing, from its IRB gateway. Read from the fabric,
    never computed here -- if EDA reallocates, this follows."""
    vn = kube("virtualnetworks", tenant)
    for irb in vn["spec"].get("irbInterfaces", []):
        return irb["spec"]["ipAddresses"][0]["ipv4Address"]["ipPrefix"]
    raise LookupError(f"virtualnetwork/{tenant} has no IRB interface")


def tenant_vlan(tenant, port, fallback):
    """Prefer the VLAN the fabric is actually using for this port."""
    for bi in kube("bridgeinterfaces").get("items", []):
        if bi["spec"].get("interface") == port and bi["spec"].get("bridgeDomain", "").startswith(tenant):
            return int(bi["spec"]["vlanID"]), "fabric"
    return int(fallback), "assignment"


def host_address(gateway_prefix, reserved):
    """THE OPEN QUESTION, deliberately visible rather than hidden. The tenant's
    SUBNET is derived from the fabric; which address inside it belongs to this
    host is an IPAM decision nothing currently owns, so it is carried as a
    reservation in inventory. What we DO enforce here is the same contract the
    edge agent enforces on the control-plane VIP: the address must fall inside
    the tenant subnet, or the host must not boot."""
    net = ipaddress.ip_network(gateway_prefix, strict=False)
    if ipaddress.ip_address(reserved) not in net:
        raise LookupError(f"reserved address {reserved} is not in the tenant subnet {net} "
                          f"-- fail closed rather than bring a host up on the wrong network")
    return reserved, net.prefixlen


def derive(mac, tenant_override=None):
    cfg = assignments()
    host = cfg["hosts"].get(mac.lower())
    if not host:
        raise LookupError(f"no inventory record for {mac}")
    pool = cfg["pools"][host["pool"]]
    tenant = tenant_override or pool["tenant"]
    node, port = leaf_port(host["name"])
    try:
        gw = tenant_subnet(tenant)
    except LookupError:
        raise LookupError(f"tenant '{tenant}' does not exist on the fabric yet. The tenant is "
                          f"created before a host is assigned into it -- run the fabric half first.")
    vlan, vlan_src = tenant_vlan(tenant, port, pool["vlan"])
    addr, prefix = host_address(gw, host["address"])
    return {
        "mac": mac, "host": host["name"], "pool": host["pool"], "tenant": tenant,
        "leaf": node, "port": port, "gateway": gw, "vlan": vlan, "vlan_source": vlan_src,
        "interface": host["interface"], "address": addr, "prefix": prefix,
    }


def userdata(d):
    # The registration token is a credential and this output goes on a screen in
    # front of other people. It is placeholdered unless explicitly asked for.
    token = "<edge-registration-token>"
    if os.environ.get("SHOW_TOKEN") == "1":
        token = os.environ.get("EDGE_REGISTRATION_TOKEN", token)
    endpoint = os.environ.get("PALETTE_ENDPOINT", "https://palette.example.com")
    endpoint = endpoint.replace("https://", "").replace("http://", "")
    project = os.environ.get("PALETTE_PROJECT_NAME", "Default")
    return f"""#cloud-config
stylus:
  skipStylusUpgrade: true
  site:
    edgeHostToken: {token}
    paletteEndpoint: {endpoint}
    name: {d['host']}
    projectName: {project}
    insecureSkipVerify: true
    tags:
      net-iso-provider: eda
      net-iso-interface: {d['interface']}
      net-iso-vlan: "{d['vlan']}"
      net-iso-subnet-ipv4: {d['address']}
      net-iso-subnet-prefix-length: "{d['prefix']}"
install:
  poweroff: false
"""


def explain(d):
    return "\n".join([
        f"  identity      mac {d['mac']}  ->  {d['host']}          (inventory; production: DHCP relay circuit-id)",
        f"  assignment    {d['host']}  ->  pool {d['pool']}  ->  tenant {d['tenant']}   (Palette; RFC-0021 item 13)",
        f"  cabling       {d['host']}  ->  {d['leaf']} {d['port']}   (EDA TopoLink; RFC-0021 4e replaces this read)",
        f"  addressing    tenant {d['tenant']}  ->  gateway {d['gateway']}   (EDA IRB, read live)",
        f"  vlan          {d['vlan']}   (from the {d['vlan_source']})",
        f"  host address  {d['address']}/{d['prefix']}   (reserved in inventory; IPAM owns nothing yet)",
        f"                verified inside the tenant subnet -- fail closed if it is not",
    ])


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        mac = (q.get("mac") or [""])[0]
        try:
            body = userdata(derive(mac, (q.get("tenant") or [None])[0])).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/cloud-config")
        except Exception as e:
            body = f"# {e}\n".encode()
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        sys.stderr.write("  %s - %s\n" % (self.address_string(), a[0] % a[1:]))


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--once" in args:
        t = args[args.index("--tenant") + 1] if "--tenant" in args else None
        d = derive(args[args.index("--once") + 1], t)
        if "--explain" in args:
            print(explain(d))
        else:
            print(userdata(d), end="")
    elif "--serve" in args:
        port = int(args[args.index("--serve") + 1])
        print(f"provisioning endpoint on :{port}  -- GET /userdata?mac=<mac>", file=sys.stderr)
        HTTPServer(("0.0.0.0", port), Handler).serve_forever()
    else:
        print(__doc__)
        sys.exit(2)
