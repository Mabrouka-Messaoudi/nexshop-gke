# nexshop-gke – Déploiement de NexShop et de son monitoring sur Google Kubernetes Engine

Ce dépôt décrit la migration de mon PFE (*plateforme Kubernetes hybride avec supervision par IA/ML –
AIOps*) du cluster local vers un cluster managé **GKE**. On y trouve à la fois la plateforme e-commerce
NexShop et la stack d'observabilité qui alimente les modèles de ML.

Le cluster local reste l'environnement de développement. GKE offre un environnement plus proche de la
production : nœuds plus puissants, stockage persistant managé et accès public. C'est là que la plateforme
tourne sous charge pendant la collecte des données d'entraînement.

| Dépôt | Rôle |
|-------|------|
| [`cluster-k8s`](https://github.com/Mabrouka-Messaoudi/cluster-k8s) | Cluster local hybride (Vagrant + Ansible) |
| [`microservices-java-k8s-monitoring`](https://github.com/Mabrouka-Messaoudi/microservices-java-k8s-monitoring) | Code source des microservices et déploiement sur le cluster local |
| [`monitoring-stack`](https://github.com/Mabrouka-Messaoudi/monitoring-stack) | Monitoring du cluster local |
| **`nexshop-gke`** (ce dépôt) | Application et monitoring sur GKE |

## Architecture sur GKE

- **Cluster** `nexshop-cluster`, zone `europe-west9-a` (Paris), trois node pools d'un nœud chacun.
- **Nœud de monitoring** (`pool-worker1-v2`) : label `monitoring=true` et taint
  `dedicated=monitoring:NoSchedule`, posés au niveau du node pool. Prometheus, Grafana, Loki et Tempo y
  sont isolés de l'application qu'ils observent.
- **Accès public** : les Services sont exposés en NodePort (règle de pare-feu GCP sur `tcp:30000-32767`).
  L'IP externe des nœuds change à chaque redémarrage des node pools, d'où l'utilisation d'un nom
  **DuckDNS** (`nexshop-mab.duckdns.org`) mis à jour par les scripts.
- **Stockage** : StorageClass `standard` (disque persistant GCE).
- **E-mails** : MailHog dans le cluster (SMTP de test, sans authentification).

```
Navigateur ──► frontend (nginx, HTTPS :30214) ──► /api/      ──► api-gateway ──► product / order / inventory
                                              └─► /keycloak/ ──► Keycloak       order ──► Kafka ──► notification ──► MailHog

Microservices ──► métriques  ──► Prometheus (ServiceMonitor nexshop-java-services)
              ──► logs       ──► Loki   (loki4j + Promtail)          ──► Grafana :32000
              ──► traces     ──► Tempo  (Zipkin :9411)
Collecteur AIOps ──► Prometheus :30090 · Loki :30003 · Tempo :30622
```

## Contenu

```
apps/         manifests NexShop : deployments, services, configmaps, secrets de démo, PVC,
              nginx.conf du frontend, modèle du realm Keycloak
monitoring/   values Helm (kube-prometheus-stack, Loki, Promtail, Tempo), ServiceMonitors,
              NodePorts pour le collecteur AIOps
scripts/      deploy.sh, install-monitoring.sh, pin-versions.sh, restart_cluster.ps1,
              test-nexshop-gke.sh, test_metrics.sh, seed_products.sh
```

## Prérequis

- Un cluster GKE avec le node pool de monitoring décrit plus haut, et `kubectl` connecté
  (`gcloud container clusters get-credentials nexshop-cluster --zone europe-west9-a`)
- Helm 3, `openssl`, `python3`, `curl` et un shell bash (Git Bash sous Windows convient)
- Un sous-domaine DuckDNS
- Les images Docker des microservices, construites par la CI du dépôt `microservices-java-k8s-monitoring`

## Configuration

```bash
cp secrets.env.example secrets.env   # puis renseigner les valeurs
```

`secrets.env` est ignoré par Git. Il contient le token DuckDNS, l'utilisateur Keycloak de test et le mot de
passe Grafana. Les mots de passe des bases de données dans `apps/04-secrets.yaml` sont des valeurs de
démonstration : ces bases ne sont joignables que depuis le cluster.

## Déploiement

```bash
bash scripts/pin-versions.sh         # une fois : fige les versions des charts dans monitoring/versions.env
bash scripts/install-monitoring.sh   # 1. observabilité
bash scripts/deploy.sh               # 2. application
bash scripts/test-nexshop-gke.sh     # 3. test de bout en bout
```

`deploy.sh` génère le certificat TLS auto-signé du frontend, crée le realm Keycloak à partir du modèle
`apps/realm-export.json`, renseigne l'issuer des jetons à partir du NodePort réel de Keycloak, applique les
manifests et met à jour DuckDNS.

## Exploitation au quotidien

Pour limiter les coûts, les node pools sont ramenés à zéro nœud entre deux sessions :

```powershell
powershell -ExecutionPolicy Bypass -File scripts\restart_cluster.ps1 -Action stop
powershell -ExecutionPolicy Bypass -File scripts\restart_cluster.ps1 -Action start
```

Au démarrage, le script recrée le volume de Kafka. Après un arrêt complet, Kafka et Zookeeper ne
s'accordent plus sur l'identifiant du cluster (`InconsistentClusterIdException`), et les messages Kafka
n'ont pas besoin d'être conservés. Il relance ensuite schema-registry. Lancer ensuite
`test-nexshop-gke.sh`, qui met DuckDNS à jour avec la nouvelle IP.

## Vérification des données de monitoring

- `scripts/test_metrics.sh` interroge les 22 indicateurs utilisés par le collecteur AIOps (17 PromQL,
  3 LogQL, 2 TraceQL) et signale ceux qui ne renvoient aucune donnée.
- `scripts/seed_products.sh` crée environ 1 500 produits. Les scénarios de charge paginés (OOM) ont besoin
  d'un catalogue volumineux pour solliciter réellement la mémoire de product-service. Les requêtes partent
  par petits lots pour ne pas ouvrir le circuit breaker de l'api-gateway.

## Limites connues

- **Issuer Keycloak** : il dépend du NodePort de Keycloak, attribué par Kubernetes. Il est donc calculé au
  déploiement, et `test-nexshop-gke.sh` le corrige si le Service a été recréé.
- **Images** : seule l'api-gateway utilise un tag daté. Les autres microservices utilisent `latest`, ce qui
  rend un redéploiement dépendant de la dernière image publiée.
- **Certificat auto-signé** : le navigateur affiche un avertissement. Un Ingress GKE avec certificat géré
  le supprimerait, mais n'était pas nécessaire pour le PFE.
- **Pas de haute disponibilité** : une réplique par composant.
