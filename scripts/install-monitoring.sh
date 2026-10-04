#!/usr/bin/env bash
# =============================================================================
# Installe la stack d'observabilité sur GKE (namespace monitoring) :
#   kube-prometheus-stack (Prometheus, Grafana, Alertmanager), Loki, Promtail, Tempo
# Le nœud de monitoring porte déjà le label monitoring=true et le taint
# dedicated=monitoring:NoSchedule (posés au niveau du node pool pool-worker1-v2).
# Usage : bash scripts/install-monitoring.sh
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_secrets GRAFANA_ADMIN_PASSWORD
MON="$ROOT_DIR/monitoring"
NS_MON="monitoring"
TIMEOUT="10m"

[ -f "$MON/versions.env" ] || { fail "monitoring/versions.env absent : lancer d'abord « bash scripts/pin-versions.sh »"; exit 1; }
# shellcheck source=/dev/null
source "$MON/versions.env"
for v in KPS_VERSION LOKI_VERSION PROMTAIL_VERSION TEMPO_VERSION; do
  [ -n "${!v:-}" ] || { fail "$v vide dans monitoring/versions.env"; exit 1; }
done

kubectl get nodes -l monitoring=true --no-headers | grep -q . \
  || { fail "Aucun nœud avec le label monitoring=true"; exit 1; }

info "Namespace et secret Grafana"
kubectl create namespace "$NS_MON" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS_MON" create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Dépôts Helm"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update

install_chart() {
  local release="$1" chart="$2" version="$3" values="$4"
  info "$release ($chart $version)"
  helm upgrade --install "$release" "$chart" \
    --namespace "$NS_MON" --version "$version" --values "$values" \
    --timeout "$TIMEOUT" --atomic --cleanup-on-fail
}

install_chart kube-prometheus-stack prometheus-community/kube-prometheus-stack "$KPS_VERSION"      "$MON/kube-prometheus-stack-values.yaml"
install_chart loki                  grafana/loki                               "$LOKI_VERSION"     "$MON/loki-values.yaml"
install_chart promtail              grafana/promtail                           "$PROMTAIL_VERSION" "$MON/promtail-values.yaml"
install_chart tempo                 grafana/tempo                              "$TEMPO_VERSION"    "$MON/tempo-values.yaml"

info "ServiceMonitors et NodePorts"
kubectl apply -f "$MON/servicemonitor-nexshop.yaml"
kubectl apply -f "$MON/sm-tempo.yaml"
kubectl apply -f "$MON/monitoring-nodeports.yaml"

kubectl get pods -n "$NS_MON" -o wide
pass "Grafana    : http://<IP externe du nœud>:32000 (admin / GRAFANA_ADMIN_PASSWORD)"
pass "Prometheus : :30090   Loki : :30003   Tempo : :30622"
