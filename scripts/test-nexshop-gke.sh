#!/bin/bash

# ============================================================
#  NexShop — Test End-to-End Backend (GKE + DuckDNS + firewall)
#  Prérequis :
#    - Règle de pare-feu GCP ouverte sur tcp:30000-32767
#    - secrets.env renseigné (DuckDNS, utilisateur Keycloak de test)
#  Usage : bash scripts/test-nexshop-gke.sh
# ============================================================

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_secrets DUCKDNS_DOMAIN DUCKDNS_TOKEN TEST_USERNAME TEST_PASSWORD

separator() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; }

check_http() {
  local label=$1 expected=$2 actual=$3 body=$4
  if [ "$actual" = "$expected" ]; then
    pass "$label → HTTP $actual"
    [ -n "$body" ] && echo "    $body"
  else
    fail "$label → HTTP $actual (attendu $expected)"
    [ -n "$body" ] && echo "    $body"
  fi
}

# ============================================================
separator
info "ÉTAPE 0 — IP externe, DuckDNS, NodePorts et issuer Keycloak"
separator

update_duckdns

GATEWAY_PORT=$(get_nodeport "api-gateway" 9000)
KEYCLOAK_PORT=$(get_nodeport "keycloak" 8080)
FRONTEND_HTTP_PORT=$(get_nodeport "frontend" 80)
FRONTEND_HTTPS_PORT=$(get_nodeport "frontend" 443)
KAFKAUI_PORT=$(get_nodeport "kafka-ui" 8080)

if [ -z "$GATEWAY_PORT" ] || [ -z "$KEYCLOAK_PORT" ]; then
  fail "NodePort introuvable pour api-gateway ou keycloak — vérifie 'kubectl get svc -n $NAMESPACE'"
  exit 1
fi

pass "api-gateway NodePort: $GATEWAY_PORT"
pass "keycloak NodePort: $KEYCLOAK_PORT"
pass "frontend NodePort (http/https): $FRONTEND_HTTP_PORT / $FRONTEND_HTTPS_PORT"
pass "kafka-ui NodePort: $KAFKAUI_PORT"

GATEWAY="http://${DUCKDNS_HOST}:$GATEWAY_PORT"
KEYCLOAK="http://${DUCKDNS_HOST}:$KEYCLOAK_PORT"
EXPECTED_ISSUER="http://${DUCKDNS_HOST}:${KEYCLOAK_PORT}/realms/${REALM}"

# --- Vérifier / corriger l'issuer dans le ConfigMap ---
CURRENT_ISSUER=$(kubectl get configmap nexshop-config -n "$NAMESPACE" -o jsonpath='{.data.KEYCLOAK_ISSUER_URI}')

if [ "$CURRENT_ISSUER" = "$EXPECTED_ISSUER" ]; then
  pass "Issuer Keycloak déjà correct: $CURRENT_ISSUER"
else
  warn "Issuer désynchronisé (actuel: $CURRENT_ISSUER)"
  info "Correction du ConfigMap → $EXPECTED_ISSUER"
  kubectl patch configmap nexshop-config -n "$NAMESPACE" --type merge \
    -p "{\"data\":{\"KEYCLOAK_ISSUER_URI\":\"$EXPECTED_ISSUER\"}}" > /dev/null

  info "Redémarrage de api-gateway pour appliquer le nouvel issuer..."
  kubectl rollout restart deployment api-gateway -n "$NAMESPACE" > /dev/null
  kubectl rollout status deployment api-gateway -n "$NAMESPACE" --timeout=400s
  if [ $? -ne 0 ]; then
    fail "Le rollout de api-gateway n'a pas abouti à temps"
    exit 1
  fi
  pass "api-gateway redémarré avec le nouvel issuer"
fi

# ============================================================
separator
info "ÉTAPE 1 — Vérification des pods"
separator

ALL_RUNNING=true
while IFS= read -r line; do
  NAME=$(echo "$line" | awk '{print $1}')
  READY=$(echo "$line" | awk '{print $2}')
  STATUS=$(echo "$line" | awk '{print $3}')
  RESTARTS=$(echo "$line" | awk '{print $4}')
  if [ "$STATUS" = "Running" ] && [ "$READY" = "1/1" ]; then
    pass "$NAME ($RESTARTS restarts)"
  else
    fail "$NAME — STATUS: $STATUS READY: $READY"
    ALL_RUNNING=false
  fi
done < <(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "^$")

[ "$ALL_RUNNING" = false ] && warn "Certains pods ne sont pas prêts — le test continue quand même"

# ============================================================
separator
info "ÉTAPE 2 — Obtention du token JWT (user: $TEST_USERNAME)"
separator

RESPONSE=$(curl -s -X POST "$KEYCLOAK/realms/$REALM/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=password" --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "username=$TEST_USERNAME" --data-urlencode "password=$TEST_PASSWORD" \
  --data-urlencode "scope=openid")

TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "None" ]; then
  fail "Impossible d'obtenir le token JWT"
  echo "  Réponse: $RESPONSE"
  exit 1
fi

EXPIRES=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires_in','?'))" 2>/dev/null)
pass "Token JWT obtenu pour '$TEST_USERNAME' (expire dans ${EXPIRES}s)"

ISS=$(echo "$TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('iss','?'))" 2>/dev/null)
if [ "$ISS" = "$EXPECTED_ISSUER" ]; then
  pass "Issuer du token cohérent: $ISS"
else
  warn "Issuer du token ($ISS) différent de l'attendu ($EXPECTED_ISSUER) — risque de 401 à venir"
fi

EMAIL=$(echo "$TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; p=json.load(sys.stdin); print(p.get('email','?'))" 2>/dev/null)
FIRSTNAME=$(echo "$TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; p=json.load(sys.stdin); print(p.get('given_name','?'))" 2>/dev/null)
LASTNAME=$(echo "$TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; p=json.load(sys.stdin); print(p.get('family_name','?'))" 2>/dev/null)
pass "User: $FIRSTNAME $LASTNAME <$EMAIL>"

# ============================================================
separator
info "ÉTAPE 3 — Création d'un produit"
separator

SKU="test-sku-$(date +%s)"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$GATEWAY/api/product" \
  -d "{\"name\":\"Test Product\",\"description\":\"Test description\",\"skuCode\":\"$SKU\",\"price\":99.99}")

HTTP=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)
check_http "POST /api/product" "201" "$HTTP" "$BODY"

# ============================================================
separator
info "ÉTAPE 4 — Liste des produits"
separator

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$GATEWAY/api/product")

HTTP=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)
COUNT=$(echo "$BODY" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
check_http "GET /api/product" "200" "$HTTP" "$COUNT produit(s) en base"

# ============================================================
separator
info "ÉTAPE 5 — Ajout de stock (inventory)"
separator

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$GATEWAY/api/inventory" \
  -d "{\"skuCode\":\"$SKU\",\"quantity\":50}")

HTTP=$(echo "$RESPONSE" | tail -1)
check_http "POST /api/inventory" "201" "$HTTP"

# ============================================================
separator
info "ÉTAPE 6 — Vérification du stock"
separator

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$GATEWAY/api/inventory?skuCode=$SKU&quantity=1")

HTTP=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)
check_http "GET /api/inventory?skuCode=$SKU&quantity=1" "200" "$HTTP" "En stock: $BODY"

# ============================================================
separator
info "ÉTAPE 7 — Passage d'une commande"
separator

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$GATEWAY/api/order" \
  -d "{
    \"skuCode\":\"$SKU\",
    \"price\":99.99,
    \"quantity\":1,
    \"userDetails\":{
      \"email\":\"$EMAIL\",
      \"firstName\":\"$FIRSTNAME\",
      \"lastName\":\"$LASTNAME\"
    }
  }")

HTTP=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)
check_http "POST /api/order" "201" "$HTTP" "$BODY"

# ============================================================
separator
info "ÉTAPE 8 — Vérification des endpoints"
separator

HTTP=$(curl -s -o /dev/null -w "%{http_code}" -k "https://${DUCKDNS_HOST}:$FRONTEND_HTTPS_PORT/")
check_http "Frontend HTTPS :$FRONTEND_HTTPS_PORT" "200" "$HTTP"

HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${DUCKDNS_HOST}:$KAFKAUI_PORT/")
check_http "Kafka UI :$KAFKAUI_PORT" "200" "$HTTP"

HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY/actuator/health")
check_http "API Gateway health" "200" "$HTTP"

HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$KEYCLOAK/realms/$REALM/.well-known/openid-configuration")
check_http "Keycloak OIDC" "200" "$HTTP"

# ============================================================
separator
echo -e "\n${GREEN}  ✅ Test end-to-end NexShop terminé !${NC}\n"
echo -e "  Récap accès navigateur (hostname fixe, survit aux rescales) :"
echo -e "    Frontend  : https://${DUCKDNS_HOST}:$FRONTEND_HTTPS_PORT"
echo -e "    Gateway   : $GATEWAY"
echo -e "    Keycloak  : $KEYCLOAK"
echo -e "    Kafka UI  : http://${DUCKDNS_HOST}:$KAFKAUI_PORT"
separator
