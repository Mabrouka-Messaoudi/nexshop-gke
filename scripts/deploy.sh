#!/usr/bin/env bash
# =============================================================================
# Déploie l'application NexShop sur GKE (namespace nexshop).
# Prérequis : kubectl connecté au cluster, secrets.env renseigné, monitoring installé
# (scripts/install-monitoring.sh) pour que les logs et les traces aient une destination.
# Usage : bash scripts/deploy.sh
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_secrets DUCKDNS_DOMAIN DUCKDNS_TOKEN TEST_USERNAME TEST_PASSWORD
APPS="$ROOT_DIR/apps"
PUBLIC_HOST="${DUCKDNS_HOST}:${FRONTEND_HTTPS_PORT}"

info "Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

info "Secrets et certificat TLS du frontend"
kubectl apply -n "$NAMESPACE" -f "$APPS/04-secrets.yaml"
if ! kubectl get secret frontend-tls -n "$NAMESPACE" >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "$TMP/tls.key" -out "$TMP/tls.crt" \
    -subj "/CN=${DUCKDNS_HOST}/O=nexshop" -addext "subjectAltName=DNS:${DUCKDNS_HOST}" 2>/dev/null
  kubectl create secret tls frontend-tls -n "$NAMESPACE" --cert="$TMP/tls.crt" --key="$TMP/tls.key"
  rm -rf "$TMP"
  pass "Certificat auto-signé généré pour $DUCKDNS_HOST"
else
  pass "frontend-tls déjà présent, conservé"
fi

info "ConfigMaps (nginx du frontend, realm Keycloak)"
kubectl create configmap frontend-nginx-config -n "$NAMESPACE" \
  --from-file=nginx.conf="$APPS/nginx.conf" --dry-run=client -o yaml | kubectl apply -f -
# python plutôt que sed : le mot de passe peut contenir des caractères spéciaux
python3 -c 'import os,sys; s=open(sys.argv[1],encoding="utf-8").read(); s=s.replace("__TEST_USERNAME__",os.environ["TEST_USERNAME"]).replace("__TEST_PASSWORD__",os.environ["TEST_PASSWORD"]); open(sys.argv[2],"w",encoding="utf-8").write(s)' \
  "$APPS/realm-export.json" "$ROOT_DIR/.realm-export.tmp.json"
kubectl create configmap keycloak-realm -n "$NAMESPACE" \
  --from-file=realm-export.json="$ROOT_DIR/.realm-export.tmp.json" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$ROOT_DIR/.realm-export.tmp.json"

info "Volumes et Services"
kubectl apply -n "$NAMESPACE" -f "$APPS/05-pvc.yaml"
kubectl apply -n "$NAMESPACE" -f "$APPS/02-services.yaml"

# L'issuer des JWT dépend du NodePort attribué à Keycloak : il n'est connu qu'une fois le Service créé.
KEYCLOAK_PORT=$(get_nodeport keycloak 8080)
ISSUER="http://${DUCKDNS_HOST}:${KEYCLOAK_PORT}/realms/${REALM}"
sed "s|__KEYCLOAK_ISSUER_URI__|${ISSUER}|" "$APPS/03-configmaps.yaml" | kubectl apply -n "$NAMESPACE" -f -
pass "KEYCLOAK_ISSUER_URI = $ISSUER"

info "Deployments"
kubectl apply -n "$NAMESPACE" -f "$APPS/01-deployments.yaml"

info "DuckDNS"
update_duckdns

info "Attente des déploiements (les services Java démarrent en plusieurs minutes)"
for dep in $(kubectl get deploy -n "$NAMESPACE" -o name); do
  kubectl rollout status "$dep" -n "$NAMESPACE" --timeout=600s || warn "$dep pas encore prêt"
done

echo ""
pass "Frontend : https://${PUBLIC_HOST} (certificat auto-signé)"
echo "  Test de bout en bout : bash scripts/test-nexshop-gke.sh"
