#!/usr/bin/env bash
# =============================================================================
# demo-palette.sh — the Palette-side walkthrough, in Tyler's running order.
#
#   WHAT WE HAVE
#     1  Palette edge host list
#     2  the VMs, and the agent installed on them
#     3  hosts tagged from the user-data configured before registration
#     4  those tag values are VLANs EDA configured
#     5  the designated interface, configured on the VM
#     6  an edge cluster on that VM, Ready
#     7  where the cluster's traffic actually goes
#   WHERE WE ARE GOING
#     8  PaletteAI manages the EDA CRs
#     9  PaletteAI generates edge-agent configuration
#   ASSUMPTIONS
#    10  stated plainly, because both change the shape of the answer
#
# Presented to a mixed Palette/Nokia room: everything printed is for the
# audience. No presenter cues.
#
# CONFIG: as demo-record.sh — EDGE_IP, PALETTE_API_KEY, EDA_KUBECONFIG, KCTX.
#   AUTO=1 auto-advance   TYPE=0 no typewriter
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT_DIR/.env" ] && set -a && . "$ROOT_DIR/.env" && set +a

: "${KCTX:=kind-eda-demo}"; : "${NS:=eda}"
: "${EDGE_IP:=}"; : "${DEMO_HOST_UID:=lab-gpu-01}"
: "${DEMO_CLUSTER:=${CLUSTER_NAME:-eda-iso-demo}}"
: "${AUTO:=0}"; : "${TYPE:=1}"
: "${PALETTE_API_KEY:=}"
PALETTE="${PALETTE_ENDPOINT:-https://palette.example.com}"
PROJECT="${PALETTE_PROJECT_UID:-<project-uid>}"
COMPANION="$ROOT_DIR/docs/companion.md"

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
arc(){  printf '\n%s  ── %s ──%s\n' "$B$TEAL" "$1" "$R"; }
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
run(){ local c="$1"; printf '\n%s  $ %s' "$B" "$R"
  if [ "$TYPE" = 1 ]; then local i; for ((i=0;i<${#c};i++)); do printf '%s' "${c:$i:1}"; sleep 0.012; done; printf '\n'
  else printf '%s\n' "$c"; fi
  eval "$c" 2>&1 | sed 's/^/    /'; }
run_masked(){ local s="$1" r="$2"; printf '\n%s  $ %s' "$B" "$R"
  if [ "$TYPE" = 1 ]; then local i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}"; sleep 0.012; done; printf '\n'
  else printf '%s\n' "$s"; fi
  eval "$r" 2>&1 | sed 's/^/    /'; }
k(){ kubectl --context "$KCTX" -n "$NS" "$@"; }
S(){ sshpass -p "${VM_PASSWORD:-demo}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=8 "${VM_USER:-demo}@$EDGE_IP" "$@"; }
KC(){ S "sudo k3s kubectl $*"; }

[ -n "$EDGE_IP" ] || { echo "EDGE_IP unset — export it, or run make host"; exit 1; }

clear
printf '%s%s\n' "$B$TEAL" '
   ███████ ██████   ███████  ██████ ████████ ██████   ██████
   ██      ██   ██  ██      ██         ██    ██   ██ ██    ██
   ███████ ██████   █████   ██         ██    ██████  ██    ██   ×  N O K I A   E D A
        ██ ██       ██      ██         ██    ██   ██ ██    ██
   ███████ ██       ███████  ██████    ██    ██   ██  ██████
'
printf '%s   Network isolation, end to end — what we have, and where it goes%s\n' "$B" "$R"
note "   $(date -u +%Y-%m-%d)  ·  EDA 26.4.3  ·  SR Linux 26.3.1  ·  edge agent v4.9.39-rc.4"

arc "WHAT WE HAVE"

. "$HERE/beats-palette.sh"

# ---------------------------------------------------------------------------
# One page per beat. BEATS overrides the running order; every beat is a function
# so the cursor can move backwards as well as forwards.
BEATS="${BEATS:-1 2 3 4 5 6 7 8 9 10}"
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
