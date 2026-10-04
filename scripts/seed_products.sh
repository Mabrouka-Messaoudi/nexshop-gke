#!/bin/bash
# ============================================================
#  NexShop — Seed en masse de produits (pour que k6_oom_ramp.js ait de la
#  vraie donnée à paginer -- son propre commentaire dit "Base confirmée avec
#  >1000 produits, donc chaque page est pleine". Avec seulement 9 produits,
#  chaque page paginée revient quasi vide : Spring n'a presque rien à
#  sérialiser, et l'OOM ne se déclenche jamais malgré la charge k6.)
#
#  Réutilise le même flux d'authentification que test-nexshop-gke.sh
#  (fonctions partagées dans common.sh).
#
#  Usage : bash scripts/seed_products.sh [nombre_de_produits] [taille_lot] [pause_s]
#  Exemple : bash scripts/seed_products.sh 1500 5 1
# ============================================================
set -uo pipefail   # PAS de -e : un produit qui échoue ne doit pas arrêter tout le seed

N_PRODUCTS="${1:-1500}"
BATCH_SIZE="${2:-5}"       # requêtes en parallèle par lot -- volontairement bas :
                            # api-gateway a un circuit breaker Resilience4j
                            # (FAILURERATETHRESHOLD=50%, SLOWCALLRATETHRESHOLD=50%)
                            # qui s'ouvre sous charge concurrente et rejette tout en
                            # cascade une fois ouvert -- vérifié en pratique : 20 en
                            # parallèle = 100% d'échec, la logique du script elle-même
                            # étant par ailleurs saine (validée séparément).
BATCH_DELAY="${3:-1}"      # secondes de pause entre deux lots, laisse le temps au
                            # circuit breaker de rester dans sa fenêtre "fermé"
TOKEN_REFRESH_EVERY=200    # nouveau token toutes les N créations (JWT expire ~300s)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_secrets DUCKDNS_DOMAIN DUCKDNS_TOKEN TEST_USERNAME TEST_PASSWORD

# ===== Découverte réseau (identique à test-nexshop-gke.sh) =====
info "Découverte réseau"
update_duckdns

GATEWAY_PORT=$(get_nodeport "api-gateway" 9000)
KEYCLOAK_PORT=$(get_nodeport "keycloak" 8080)
[ -z "$GATEWAY_PORT" ] || [ -z "$KEYCLOAK_PORT" ] && { fail "NodePort introuvable pour api-gateway/keycloak"; exit 1; }

GATEWAY="http://${DUCKDNS_HOST}:$GATEWAY_PORT"
KEYCLOAK="http://${DUCKDNS_HOST}:$KEYCLOAK_PORT"
pass "Gateway=$GATEWAY  Keycloak=$KEYCLOAK"

TOKEN=$(get_token)
[ -z "$TOKEN" ] && { fail "Impossible d'obtenir le token JWT initial"; exit 1; }
pass "Token JWT obtenu"
rm -f /tmp/seed_failure_*.log

# ===== État initial =====
BEFORE=$(curl -s -H "Authorization: Bearer $TOKEN" "$GATEWAY/api/product" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
info "Produits en base avant seed : $BEFORE"
info "Objectif : +$N_PRODUCTS produits, par lots de $BATCH_SIZE en parallèle"

# ===== Fonction de création d'un produit (appelée en parallèle) =====
create_one() {
  local i="$1" token="$2" gateway="$3"
  # SKU basé sur l'index + PID du sous-shell xargs -- jamais vide, jamais ambigu,
  # contrairement à $RANDOM qui peut se comporter différemment selon le contexte
  # d'exécution du shell (observé produire une chaîne vide dans certains cas).
  local sku="seed-sku-$(date +%s)-${i}-$$"
  # Prix dérivé de l'index (pas de $RANDOM ici non plus, même raison) -- variation
  # simple mais suffisante pour avoir des valeurs différentes.
  local price=$(( (i % 190) + 10 ))
  local response code
  # Texte en ASCII pur (pas d'accent) -- un accent dans un payload -d entre
  # guillemets peut se corrompre selon l'encodage du terminal (observé en pratique
  # sous Git Bash/Windows), provoquant un JSON invalide côté serveur -> 400.
  response=$(curl -s -w "\nHTTPCODE:%{http_code}" -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "$gateway/api/product" \
    -d "{\"name\":\"Seed Product $i\",\"description\":\"Produit genere pour charge k6\",\"skuCode\":\"$sku\",\"price\":${price}.99}")
  code=$(echo "$response" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)
  if [ "$code" != "201" ] && [ "$i" -lt 5 ]; then
    # Garde une trace des tout premiers échecs pour un vrai diagnostic -- fichier
    # dédié par index plutôt qu'un verrou partagé (flock n'est pas garanti sous
    # Git Bash / Windows), donc sans risque de corruption entre écritures
    # parallèles.
    echo "$response" > "/tmp/seed_failure_${i}.log"
  fi
  echo "$code"
}
export -f create_one

# ===== Boucle de seed par lots, avec renouvellement de token =====
CREATED=0
FAILED=0
START_TS=$(date +%s)

while [ "$CREATED" -lt "$N_PRODUCTS" ]; do
  # Renouvelle le token périodiquement (JWT expire ~300s, un run de 1500 produits
  # peut largement dépasser ça)
  if [ $((CREATED % TOKEN_REFRESH_EVERY)) -eq 0 ]; then
    NEW_TOKEN=$(get_token)
    if [ -n "$NEW_TOKEN" ]; then
      TOKEN="$NEW_TOKEN"
    else
      warn "Renouvellement de token échoué, on continue avec l'ancien"
    fi
  fi

  REMAINING=$((N_PRODUCTS - CREATED))
  THIS_BATCH=$((REMAINING < BATCH_SIZE ? REMAINING : BATCH_SIZE))

  RESULTS=$(seq "$CREATED" $((CREATED + THIS_BATCH - 1)) \
    | xargs -P "$BATCH_SIZE" -I{} bash -c 'create_one "$@"' _ {} "$TOKEN" "$GATEWAY")

  OK_COUNT=$(echo "$RESULTS" | grep -c "^201$")
  BAD_COUNT=$((THIS_BATCH - OK_COUNT))
  CREATED=$((CREATED + THIS_BATCH))
  FAILED=$((FAILED + BAD_COUNT))

  ELAPSED=$(( $(date +%s) - START_TS ))
  echo -ne "\r  ${CREATED}/${N_PRODUCTS} créés (${FAILED} échecs) -- ${ELAPSED}s écoulées   "

  # Pause entre les lots -- laisse le circuit breaker d'api-gateway rester dans sa
  # fenêtre "fermé" plutôt que de l'ouvrir sous rafale continue.
  [ "$CREATED" -lt "$N_PRODUCTS" ] && sleep "$BATCH_DELAY"
done
echo ""

# ===== Vérification finale (même appel non paginé que test-nexshop-gke.sh) =====
AFTER=$(curl -s -H "Authorization: Bearer $TOKEN" "$GATEWAY/api/product" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
info "Seed terminé : $CREATED tentatives, $FAILED échec(s) en $(( $(date +%s) - START_TS ))s."
pass "Produits en base : $BEFORE -> $AFTER"

if [ "$FAILED" -gt 0 ] && ls /tmp/seed_failure_*.log >/dev/null 2>&1; then
  warn "Détail des premiers échecs (voir /tmp/seed_failure_*.log) :"
  for f in /tmp/seed_failure_*.log; do
    echo "  --- $f ---"
    cat "$f" | sed 's/^/  /'
  done
fi
