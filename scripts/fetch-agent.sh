#!/usr/bin/env bash
# =============================================================================
# fetch-agent.sh — download the Palette edge agent (stylus agent-mode) build
# this demo pins, and verify it against a published checksum.
#
# The build is SpectroCloud proprietary and is NOT redistributed in this
# repository. It is served from Artifactory to a read-only, scoped, expiring
# token that is sent to evaluators through a separate secure channel.
#
# Put the token in .env (see .env.example). It is never committed.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

: "${JFROG_URL:=https://insightsoftmax.jfrog.io}"
: "${JFROG_REPO:=nokia-eda-demo}"
: "${AGENT_VERSION:=v4.9.39-rc.4}"
: "${AGENT_PATH:=stylus/${AGENT_VERSION}/agent-mode-linux-amd64.tar}"
: "${AGENT_SHA256:=833a6c93e7e381fcb57d63020106c9d79068e5a4f7b4d6aefae8121b00219502}"
DEST="$ROOT/.artifacts/agent-mode-linux-amd64.tar"

if [ -z "${JFROG_TOKEN:-}" ] || [ "${JFROG_TOKEN}" = "REPLACE_ME" ]; then
  cat >&2 <<EOF
JFROG_TOKEN is not set.

  1. cp .env.example .env
  2. paste the read-only token you were sent into JFROG_TOKEN
  3. make agent

The token is read-only, limited to the '${JFROG_REPO}' repository, and expires.
If yours has lapsed, ask for a new one — do not ask for a broader token.
EOF
  exit 1
fi

mkdir -p "$(dirname "$DEST")"

if [ -f "$DEST" ] && [ "$(sha256sum "$DEST" | cut -d' ' -f1)" = "$AGENT_SHA256" ]; then
  echo "  agent already present and verified: $DEST"
  exit 0
fi

URL="$JFROG_URL/artifactory/$JFROG_REPO/$AGENT_PATH"
echo "  downloading $AGENT_VERSION from $JFROG_REPO …"
if ! curl -fSL --progress-bar -H "Authorization: Bearer $JFROG_TOKEN" -o "$DEST.part" "$URL"; then
  echo "download failed — check the token has not expired, and that $URL is correct" >&2
  rm -f "$DEST.part"; exit 1
fi

got=$(sha256sum "$DEST.part" | cut -d' ' -f1)
if [ "$got" != "$AGENT_SHA256" ]; then
  echo "CHECKSUM MISMATCH — refusing to use this file" >&2
  echo "  expected $AGENT_SHA256" >&2
  echo "  got      $got" >&2
  rm -f "$DEST.part"; exit 1
fi

mv "$DEST.part" "$DEST"
echo "  verified sha256 $AGENT_SHA256"
echo "  agent ready: $DEST"
