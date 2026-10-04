#!/usr/bin/env bash
# Lit les versions des charts actuellement déployés et les écrit dans versions.env.
# À lancer une fois sur une machine qui a accès au cluster, puis commiter versions.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../monitoring" && pwd)"
NAMESPACE="monitoring"

chart_version() {
  local release="$1" chart
  chart=$(helm list -n "$NAMESPACE" --filter "^${release}\$" -o json \
          | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p')
  [ -n "$chart" ] || { echo "✖ release $release introuvable dans $NAMESPACE" >&2; exit 1; }
  echo "${chart##*-}"
}

cat > "$SCRIPT_DIR/versions.env" <<VERSIONS
# Versions des charts Helm, relevées sur le cluster le $(date +%F)
KPS_VERSION=$(chart_version kube-prometheus-stack)
LOKI_VERSION=$(chart_version loki)
PROMTAIL_VERSION=$(chart_version promtail)
TEMPO_VERSION=$(chart_version tempo)
VERSIONS

cat "$SCRIPT_DIR/versions.env"
