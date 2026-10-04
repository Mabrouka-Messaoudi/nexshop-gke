#!/usr/bin/env bash
# Fonctions partagées par les scripts : chargement de secrets.env, DuckDNS, NodePorts.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="nexshop"
REALM="spring-microservices-security-realm"
CLIENT_ID="angular-client"
FRONTEND_HTTPS_PORT=30214

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}  ✓ $1${NC}"; }
fail() { echo -e "${RED}  ✗ $1${NC}"; }
info() { echo -e "${BLUE}▶ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }

load_secrets() {
  [ -f "$ROOT_DIR/secrets.env" ] \
    || { fail "secrets.env absent : cp secrets.env.example secrets.env puis le renseigner"; exit 1; }
  set -a
  # shellcheck source=/dev/null
  source "$ROOT_DIR/secrets.env"
  set +a
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { fail "$v vide dans secrets.env"; exit 1; }
  done
  DUCKDNS_HOST="${DUCKDNS_DOMAIN:-nexshop-mab}.duckdns.org"
}

# Pointe le nom DuckDNS sur l'IP externe d'un nœud (elle change à chaque redémarrage des node pools).
update_duckdns() {
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
  [ -n "$NODE_IP" ] || { fail "Impossible de récupérer l'IP externe d'un nœud"; exit 1; }
  local resp
  resp=$(curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${NODE_IP}")
  [ "$resp" = "OK" ] || { fail "Échec de la mise à jour DuckDNS (réponse : $resp)"; exit 1; }
  pass "DuckDNS : $DUCKDNS_HOST → $NODE_IP"
}

# $1 = Service, $2 = port du Service
get_nodeport() {
  kubectl get svc -n "$NAMESPACE" "$1" -o jsonpath="{.spec.ports[?(@.port==$2)].nodePort}"
}

get_token() {
  curl -s -X POST "$KEYCLOAK/realms/$REALM/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "username=$TEST_USERNAME" \
    --data-urlencode "password=$TEST_PASSWORD" \
    --data-urlencode "scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null
}
