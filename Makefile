# Nokia EDA tenant isolation — reproduction targets.
#
#   make deps     check every prerequisite, name what is missing
#   make agent    download + verify the pinned edge-agent build
#   make host     build the edge host from nothing (~4½ min)
#   make demo     run the walkthrough against the live fabric (Nokia cut)
#   make demo-tyler  same evidence, led by the ComputePool path (Palette cut)
#   make demo-palette  the Palette-side flow: hosts, tags, VLAN, cluster, pods
#   make demo-bootstrap  the bootstrap dependency, and the boot-time path that closes it
#   make verify   prove the last demo run was live, not cached
#   make clean    tear down demo fabric state
#   make destroy  clean, plus remove the VM and its Palette records

SHELL := /bin/bash
ROOT  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

KCTX      ?= kind-eda-demo
NS        ?= eda
VM_NAME   ?= eda-edge-01
EDGE_HOST ?= lab-gpu-01

# Populated by `make host`; override if you built the host another way.
EDGE_IP ?= $(shell cat $(ROOT)/.work/edge-ip 2>/dev/null)

.DEFAULT_GOAL := help
.PHONY: help deps agent host demo demo-tyler demo-palette demo-bootstrap verify clean destroy env

help:
	@sed -n 's/^#   //p' $(MAKEFILE_LIST) | head -13
	@echo ""
	@echo "Start here:  cp .env.example .env  &&  \$$EDITOR .env  &&  make deps"

# ---------------------------------------------------------------- prereqs
REQUIRED := curl python3 kubectl qemu-img virsh virt-install cloud-localds sshpass go
deps:
	@echo "checking prerequisites…"
	@missing=""; for b in $(REQUIRED); do \
	  command -v $$b >/dev/null 2>&1 || missing="$$missing $$b"; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo ""; echo "  MISSING:$$missing"; echo ""; \
	  echo "  Debian/Ubuntu:"; \
	  echo "    sudo apt-get install -y curl python3 qemu-utils libvirt-daemon-system \\"; \
	  echo "         virtinst cloud-image-utils sshpass golang-go"; \
	  echo "    # kubectl: https://kubernetes.io/docs/tasks/tools/"; \
	  echo ""; exit 1; \
	fi; \
	echo "  all present"
	@test -f $(ROOT)/.env || { echo ""; echo "  .env missing — cp .env.example .env"; exit 1; }
	@echo "  .env present"
	@kubectl --context $(KCTX) -n $(NS) get toponodes >/dev/null 2>&1 \
	  && echo "  EDA fabric reachable at context $(KCTX)" \
	  || echo "  ! EDA fabric NOT reachable at context $(KCTX) — see docs/runbook.md"

env:
	@echo "ROOT      $(ROOT)"
	@echo "KCTX      $(KCTX)"
	@echo "EDGE_IP   $(or $(EDGE_IP),<unset — run make host>)"
	@echo "agent     $(shell test -f $(ROOT)/.artifacts/agent-mode-linux-amd64.tar && echo present || echo absent)"

# ---------------------------------------------------------------- artifact
agent:
	@bash $(ROOT)/scripts/fetch-agent.sh

# ------------------------------------------------------------------- host
host: agent
	@bash $(ROOT)/scripts/build-edge-host.sh

# ------------------------------------------------------------------- demo
demo:
	@test -n "$(EDGE_IP)" || { echo "EDGE_IP unset — run 'make host', or export EDGE_IP=<addr>"; exit 1; }
	@EDGE_IP=$(EDGE_IP) FRISKET=$(FRISKET) bash $(ROOT)/scripts/demo-record.sh

# Same script, same evidence, different running order.
#
# The default cut is written for Nokia EDA engineers: it opens on the fabric and
# what "isolated" means in EVPN terms, then works outward to the host.
#
# Every cut is paginated: one page per section, [enter] forward, [p] back,
# [r] replay, [g N] jump, [q] quit. Set AUTO=1 to advance on a timer instead.
#
# This cut answers the Palette-side question instead — "inventory, select hosts,
# create a compute pool, apply isolation" — so it leads with section 6, the
# ComputePool path and the piece of it that is not written yet, then shows the
# sections that back it up. Section 1 (fabric internals) is dropped; every other
# section runs, and the numbering is unchanged, so cross-references still hold.
DEMO_TYLER_SECTIONS ?= 0 6 2 4 5 3 7 8 9 10
demo-tyler:
	@test -n "$(EDGE_IP)" || { echo "EDGE_IP unset — run 'make host', or export EDGE_IP=<addr>"; exit 1; }
	@EDGE_IP=$(EDGE_IP) FRISKET=$(FRISKET) SECTIONS="$(DEMO_TYLER_SECTIONS)" \
	  bash $(ROOT)/scripts/demo-record.sh

# Tyler's running order for a mixed Palette/Nokia room: start from the platform's
# own edge-host list and work outward to the fabric, rather than starting at the
# fabric. Same environment, different story.
demo-palette:
	@test -n "$(EDGE_IP)" || { echo "EDGE_IP unset — run 'make host', or export EDGE_IP=<addr>"; exit 1; }
	@EDGE_IP=$(EDGE_IP) FRISKET=$(FRISKET) bash $(ROOT)/scripts/demo-palette.sh

# The bootstrap half. Answers "who writes /var/lib/spectro/userdata at fleet
# scale", which is the question the main demo deliberately leaves open. Needs the
# tenant to exist on the fabric first -- run `make demo` (or its section 5) before
# this, or it will correctly refuse.
demo-bootstrap:
	@EDGE_IP=$(EDGE_IP) bash $(ROOT)/scripts/demo-bootstrap.sh

# Liveness proof: a cached Go test replays byte-for-byte, so output alone proves
# nothing. EDA transactions do not lie — a live run moves this counter.
verify:
	@echo "EDA transactions recorded: $$(kubectl --context $(KCTX) -n eda-system \
	  get transactionresults --no-headers 2>/dev/null | wc -l)"
	@echo "(run 'make demo' and compare — a live run adds ~8)"
	@kubectl --context $(KCTX) -n eda-system get transactionresults --no-headers 2>/dev/null | tail -4

# ------------------------------------------------------------------ clean
# Order is load-bearing: BridgeInterface, then VirtualNetwork, then BridgeDomain.
# Reversing it orphans the interface, and the dangling reference then fails EVERY
# EDA transaction until it is removed by hand.
clean:
	@echo "removing demo fabric state…"
	@for set in "nokia-demo-pool-leaf1-ethernet-1-9 nokia-demo nokia-demo-bd" \
	            "rc-smoke-pool-leaf1-ethernet-1-9 rc-smoke rc-smoke-bd"; do \
	  set -- $$set; \
	  kubectl --context $(KCTX) -n $(NS) delete bridgeinterface $$1 --ignore-not-found --timeout=60s >/dev/null 2>&1; \
	  sleep 3; \
	  kubectl --context $(KCTX) -n $(NS) delete virtualnetwork  $$2 --ignore-not-found --timeout=60s >/dev/null 2>&1; \
	  sleep 6; \
	  kubectl --context $(KCTX) -n $(NS) delete bridgedomain    $$3 --ignore-not-found --timeout=60s >/dev/null 2>&1; \
	done
	@echo "remaining demo objects: $$(kubectl --context $(KCTX) -n $(NS) \
	  get virtualnetworks,bridgedomains,bridgeinterfaces --no-headers 2>/dev/null \
	  | grep -cE 'nokia-demo|rc-smoke')"

destroy: clean
	@echo "removing the edge host and its Palette records…"
	@set -a; [ -f $(ROOT)/.env ] && . $(ROOT)/.env; set +a; \
	 cid=$$(cat $(ROOT)/.work/cluster-id 2>/dev/null); \
	 if [ -n "$$cid" ]; then \
	   curl -sk -X DELETE -H "ApiKey: $$PALETTE_API_KEY" -H "ProjectUid: $$PALETTE_PROJECT_UID" \
	     "$$PALETTE_ENDPOINT/v1/spectroclusters/$$cid" -o /dev/null -w '  cluster delete HTTP %{http_code}\n'; \
	   sleep 20; \
	 fi; \
	 sudo virsh -c $${LIBVIRT_URI:-qemu:///system} destroy $(VM_NAME) >/dev/null 2>&1; \
	 sudo virsh -c $${LIBVIRT_URI:-qemu:///system} undefine $(VM_NAME) --remove-all-storage >/dev/null 2>&1; \
	 echo "  VM removed"; \
	 curl -sk -X DELETE -H "ApiKey: $$PALETTE_API_KEY" -H "ProjectUid: $$PALETTE_PROJECT_UID" \
	   "$$PALETTE_ENDPOINT/v1/edgehosts/$(EDGE_HOST)" -o /dev/null -w '  edge host delete HTTP %{http_code}\n'
	@rm -rf $(ROOT)/.work
	@echo "  done. .artifacts kept — 'rm -rf .artifacts' to drop the agent tarball too."
