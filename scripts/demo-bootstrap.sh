#!/usr/bin/env bash
# =============================================================================
# demo-bootstrap.sh — the bootstrap dependency, and what closes it.
#
# Presented directly to the room. No presenter cues.
#
# The main demo shows a host coming up on its tenant VLAN because the isolation
# values were already in /var/lib/spectro/userdata. That file is written by hand,
# over SSH, which is honest for one host and is exactly what does not survive a
# fleet. This is the replacement: the host boots knowing only its own identity
# and is told the rest over the provisioning network.
#
# CONFIG: EDGE_IP, KCTX, NS, AUTO, TYPE — as demo-record.sh.
#         DEMO_MAC   the booting host's MAC (default: the lab VM's fabric NIC)
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT_DIR/.env" ] && set -a && . "$ROOT_DIR/.env" && set +a

: "${KCTX:=kind-eda-demo}"; : "${NS:=eda}"
: "${EDGE_IP:=}"; : "${AUTO:=0}"; : "${TYPE:=1}"
: "${DEMO_MAC:=52:54:00:26:9a:5e}"
COMPANION="$ROOT_DIR/docs/companion.md"
ENDPOINT="$HERE/provision-endpoint.py"

B=$'\e[1m'; DIM=$'\e[2m'; IT=$'\e[3m'; R=$'\e[0m'
TEAL=$'\e[38;5;30m'; SAND=$'\e[38;5;179m'; GREY=$'\e[38;5;244m'
GREEN=$'\e[38;5;35m'; BLUE=$'\e[38;5;39m'; RED=$'\e[38;5;167m'

banner(){ local t="$1"; local pad=$(( 58 - ${#t} )); [ "$pad" -lt 0 ] && pad=0
  printf '\n%s%s╔══════════════════════════════════════════════════════════════╗%s\n' "$B" "$TEAL" "$R"
  printf '%s%s║  %s%*s  ║%s\n' "$B" "$TEAL" "$t" "$pad" "" "$R"
  printf '%s%s╚══════════════════════════════════════════════════════════════╝%s\n' "$B" "$TEAL" "$R"; }
lede(){ printf '%s%s  %s%s\n' "$IT" "$SAND" "$1" "$R"; }
note(){ printf '%s     %s%s\n' "$GREY" "$1" "$R"; }
ctx(){  printf '%s  ▐ WHY%s  %s%s%s\n' "$B$BLUE" "$R" "$IT$GREY" "$1" "$R"; }
good(){ printf '%s     ✓ %s%s\n' "$GREEN" "$1" "$R"; }
bad(){  printf '%s     ✗ %s%s\n' "$RED" "$1" "$R"; }
link(){ printf '    %s▸ %s%s\n      %s%s%s\n' "$B" "$1" "$R" "$BLUE" "$2" "$R"; }
NAV=next
pause(){
  if [ "$AUTO" = 1 ]; then sleep 4; NAV=next; return 0; fi
  local k
  printf '
%s     [enter] next   [p] back   [r] replay   [g N] go to N   [q] quit%s  ' "$DIM" "$R"
  read -r k
  case "$k" in
    p|P|b|B)      NAV=prev;   return 1 ;;
    r|R)          NAV=replay; return 1 ;;
    q|Q)          NAV=quit;   return 1 ;;
    g\ *|G\ *)    NAV="goto:${k#* }"; return 1 ;;
    [0-9]*)       NAV="goto:$k"; return 1 ;;
    *)            NAV=next;   return 0 ;;
  esac
}
page_clear(){ [ "$AUTO" = 1 ] && return 0; printf '[H[2J'; }
page_mark(){ printf '%s     %s  ·  page %s of %s%s
' "$DIM" "$1" "$2" "$3" "$R"; }
run(){ local cmd="$1"; printf '\n%s  $ %s' "$B" "$R"
  if [ "$TYPE" = 1 ]; then local i; for ((i=0;i<${#cmd};i++)); do printf '%s' "${cmd:$i:1}"; sleep 0.012; done; printf '\n'
  else printf '%s\n' "$cmd"; fi
  eval "$cmd" 2>&1 | sed 's/^/    /'; }
SSH(){ sshpass -p "${VM_PASSWORD:-demo}" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 \
        "${VM_USER:-demo}@$EDGE_IP" "$@"; }

beat_1(){
# ------------------------------------------------------------------
banner "1 · The circularity"
ctx "A host's tenant interface has to exist before Kubernetes starts, because the node IP and the CNI come up on it. So the isolation values must reach the host before it can usefully talk to anything — and configuring a host's primary interface from a controller it reaches over that interface is circular."
lede "How the demo host got its values today:"
if [ -n "$EDGE_IP" ]; then
  printf '\n%s  $ %sssh lab-gpu-01 '"'"'sudo sed -n "/tags:/,/install:/p" /var/lib/spectro/userdata'"'"'\n' "$B" "$R"
  SSH 'sudo sed -n "/tags:/,/install:/p" /var/lib/spectro/userdata' 2>&1 | sed 's/^/    /'
else
  note "EDGE_IP not set — skipping the live read"
fi
echo
note "Correct, and it does not scale: that file was written by hand, over SSH, before"
note "the agent first registered. One host is fine. A fleet is not — and there is no"
note "second chance, because the agent snapshots its tags at registration and never"
note "looks again."
pause || return
}

beat_2(){
# ------------------------------------------------------------------
banner "2 · What a booting host actually knows"
ctx "Break the circle by requiring less of the host. It does not need its address; it needs to be able to ask. The provisioning network is not the tenant network, which is the whole reason this is not circular."
lede "Everything the host presents about itself — one value:"
run "echo $DEMO_MAC"
echo
note "In production this is not even a lookup. The leaf's DHCP relay inserts Option 82"
note "circuit-id — the port the request arrived on — so the fabric names the port and"
note "nothing has to resolve the host at all. The Digital Twin has no forwarding plane,"
note "so there is no relay here; we key on MAC from inventory instead. The derivation"
note "below is identical either way."
pause || return
}

beat_3(){
# ------------------------------------------------------------------
banner "3 · The derivation, live against the fabric"
ctx "Nothing per-host is authored anywhere. Identity comes from inventory, the tenant comes from the pool assignment, and everything about the network is read from EDA at the moment it is asked."
run "./scripts/provision-endpoint.py --once $DEMO_MAC --explain"
echo
note "Two of those lines are ours to change and we have said so: the cabling read is"
note "replaced by the leaf port carried on the host record (RFC-0021 §4e), and the pool"
note "to tenant mapping is what the ComputePool watcher will own (RFC-0021 item 13)."
pause || return
}

beat_4(){
# ------------------------------------------------------------------
banner "4 · What the host is served"
lede "The configuration a booting host receives, in full:"
run "./scripts/provision-endpoint.py --once $DEMO_MAC"
echo
lede "Against what is on the running host:"
if [ -n "$EDGE_IP" ]; then
  a=$("$ENDPOINT" --once "$DEMO_MAC" 2>/dev/null | sed -n '/net-iso/p')
  b=$(SSH 'sudo sed -n "/net-iso/p" /var/lib/spectro/userdata' 2>/dev/null)
  if [ -n "$a" ] && [ "$a" = "$b" ]; then
    printf '%s\n' "$a" | sed 's/^ *//;s/^/      /'
    good "Identical. Derived from the fabric, not copied from the host."
  elif [ -z "$a" ]; then
    note "The tenant is not on the fabric. It is created by the fabric half — run"
    note "\`make demo\` (or SECTIONS=5 ./scripts/demo-record.sh) before this."
  else
    bad "The two do not match."
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/    /'
  fi
else
  note "EDGE_IP not set — cannot compare against the running host"
fi
pause || return
}

beat_5(){
# ------------------------------------------------------------------
banner "5 · Proving it is a derivation, not a lookup table"
ctx "A service that returns the right answer proves nothing on its own — it could be reciting. It is a derivation only if it changes when the fabric changes, and refuses when the fabric disagrees with it."
lede "Ask for the same host against a different tenant:"
run "./scripts/provision-endpoint.py --once $DEMO_MAC --tenant tenant-a 2>&1 | tail -1"
echo
note "tenant-a's subnet is read live from its IRB. The reserved address is not inside it,"
note "so the host is not served a configuration at all."
good "Fail closed: a host that cannot be placed correctly does not boot onto the wrong network."
note "This is the same contract the edge agent enforces on the control-plane VIP."
pause || return
}

beat_6(){
# ------------------------------------------------------------------
banner "6 · What this closes, and what it does not"
good "CLOSED — per-host configuration is no longer authored. Every machine boots the"
good "same image and is told what it is. That is the fleet-scale shape."
echo
bad "NOT CLOSED — the transport. A production host gets this over PXE/iPXE or from an"
bad "out-of-band installer; this is plain HTTP on the management network. Same shape,"
bad "none of the same work, and we are not claiming otherwise."
echo
bad "NOT CLOSED — IPAM. The tenant's subnet is the fabric's. Which address inside it"
bad "belongs to a given host is a decision nothing currently owns, so it is carried as"
bad "a reservation in inventory. We would rather show that gap than paper it."
echo
note "There is also a genuinely better answer than any of this, and it is yours: DPU"
note "addressing arrives over DHCP, which removes the circularity instead of routing"
note "around it. We treat it as an optimisation rather than a prerequisite because most"
note "sites are not cabled for it — companion §8."
echo
link "Integration companion — §5.1, the bootstrap dependency" "$COMPANION"
link "Integration companion — §8, DPUs and smart NICs" "$COMPANION"
printf '\n%s   Thank you.%s\n\n' "$B$TEAL" "$R"
pause || return
}

# ---------------------------------------------------------------------------
# One page per beat. BEATS overrides the running order; every beat is a function
# so the cursor can move backwards as well as forwards.
BEATS="${BEATS:-1 2 3 4 5 6}"
read -r -a PAGES <<< "$BEATS"
N=${#PAGES[@]}
i=0
while [ "$i" -lt "$N" ]; do
  s="${PAGES[$i]}"
  page_clear
  page_mark "beat $s" "$((i+1))" "$N"
  NAV=next
  if declare -F "beat_$s" >/dev/null; then "beat_$s"
  else printf "%s     unknown beat: %s%s\n" "$RED" "$s" "$R"; fi
  case "$NAV" in
    prev)   [ "$i" -gt 0 ] && i=$((i-1)) ;;
    replay) : ;;
    quit)   printf '\n'; break ;;
    goto:*) t="${NAV#goto:}"; j=0; hit=-1
            while [ "$j" -lt "$N" ]; do [ "${PAGES[$j]}" = "$t" ] && { hit=$j; break; }; j=$((j+1)); done
            if [ "$hit" -ge 0 ]; then i=$hit
            else printf '%s     no beat %s%s\n' "$RED" "$t" "$R"; sleep 1; fi ;;
    *)      i=$((i+1)) ;;
  esac
done
