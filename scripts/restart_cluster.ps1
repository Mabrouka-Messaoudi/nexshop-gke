<#
.SYNOPSIS
    Démarre ou arrête le cluster NexShop (3 node pools GKE), avec le correctif Kafka
    intégré automatiquement au démarrage (InconsistentClusterIdException après un
    arrêt complet -- Kafka n'a aucune donnée précieuse pour la démo, donc on repart
    toujours d'un volume propre plutôt que de déboguer l'incohérence à chaque fois).

.USAGE
    powershell -ExecutionPolicy Bypass -File scripts\restart_cluster.ps1 -Action start
    powershell -ExecutionPolicy Bypass -File scripts\restart_cluster.ps1 -Action stop

    Peut être lancé depuis n'importe quel dossier : les manifests sont lus dans apps\.
    Après un démarrage, l'IP externe des nœuds change : lancer ensuite
    « bash scripts/test-nexshop-gke.sh », qui met à jour DuckDNS et l'issuer Keycloak.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("start", "stop")]
    [string]$Action,

    [string]$Cluster = "nexshop-cluster",
    [string]$Zone = "europe-west9-a",
    [string]$Namespace = "nexshop",
    [string[]]$NodePools = @("pool-worker1-v2", "pool-worker2-v2", "pool-worker3-v2")
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Invoke-Checked {
    <# Exécute une commande externe (gcloud/kubectl) et arrête le script si elle
       échoue -- $ErrorActionPreference="Stop" seul ne suffit pas pour les commandes
       externes en PowerShell, qui ne lèvent pas d'exception sur un code de sortie
       non nul, contrairement aux cmdlets natives. #>
    param(
        [string]$Description,
        [scriptblock]$Command
    )
    Write-Host "-> $Description" -ForegroundColor DarkGray
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Échec : $Description (code de sortie $LASTEXITCODE)"
    }
}

function Wait-AllNodesReady {
    param([int]$TimeoutSec = 420, [int]$ExpectedCount = 3)
    Write-Step "Attente que les $ExpectedCount nœuds soient Ready (timeout ${TimeoutSec}s)"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $raw = kubectl get nodes --no-headers 2>$null
        $lines = @($raw -split "`n" | Where-Object { $_.Trim() -ne "" })
        $readyLines = @($lines | Where-Object { $_ -match "\sReady\s" })
        Write-Host "  Nœuds Ready : $($readyLines.Count) / $ExpectedCount"
        if ($readyLines.Count -ge $ExpectedCount) {
            Write-Host "Tous les nœuds attendus sont Ready." -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 15
    }
    throw "Timeout : les $ExpectedCount nœuds ne sont pas tous devenus Ready après ${TimeoutSec}s. Vérifie 'kubectl get nodes' et les quotas GCP avant de continuer."
}

function Wait-PvcGone {
    param([string]$PvcName, [string]$Ns, [int]$TimeoutSec = 90)
    Write-Host "Attente de la suppression complète du PVC '$PvcName'..." -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $exists = kubectl get pvc $PvcName -n $Ns --ignore-not-found 2>$null
        if (-not $exists) { return }
        Start-Sleep -Seconds 3
    }
    Write-Host "  [ATTENTION] Le PVC '$PvcName' est toujours là après ${TimeoutSec}s -- probablement coincé en Terminating. On continue quand même, mais vérifie manuellement si Kafka replante." -ForegroundColor Yellow
}

function Start-NexshopCluster {
    Write-Step "1/5 -- Démarrage des node pools (0 -> 1), un par un"
    foreach ($pool in $NodePools) {
        Invoke-Checked "Resize $pool -> 1 nœud" {
            gcloud container clusters resize $Cluster --node-pool=$pool --num-nodes=1 --zone=$Zone --quiet
        }
    }

    Wait-AllNodesReady -ExpectedCount $NodePools.Count

    Write-Step "2/5 -- Vérification du label/taint monitoring sur worker1-v2"
    kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints,MONITORING:.metadata.labels.monitoring'
    Write-Host "Attendu : un nœud worker1-v2 avec TAINTS=dedicated=monitoring:NoSchedule et MONITORING=true." -ForegroundColor DarkGray
    Write-Host "(Posé au niveau du node pool à sa création -- doit revenir automatiquement, sans action manuelle.)" -ForegroundColor DarkGray

    Write-Step "3/5 -- Correctif Kafka (InconsistentClusterIdException après arrêt complet)"
    Write-Host "Kafka perd la cohérence avec Zookeeper à chaque redémarrage à froid du cluster." -ForegroundColor DarkGray
    Write-Host "Aucune donnée Kafka n'est critique pour la démo -- on repart toujours d'un volume propre." -ForegroundColor DarkGray

    kubectl delete deployment kafka -n $Namespace --ignore-not-found
    kubectl delete pvc kafka-pvc -n $Namespace --ignore-not-found
    Wait-PvcGone -PvcName "kafka-pvc" -Ns $Namespace

    $AppsDir = Join-Path $PSScriptRoot "..\apps"
    $PvcFile = Join-Path $AppsDir "05-pvc.yaml"
    $DeployFile = Join-Path $AppsDir "01-deployments.yaml"
    if (-not (Test-Path $PvcFile) -or -not (Test-Path $DeployFile)) {
        throw "05-pvc.yaml / 01-deployments.yaml introuvables dans $AppsDir"
    }

    Invoke-Checked "Réapplication de 05-pvc.yaml" { kubectl apply -f $PvcFile -n $Namespace }
    Invoke-Checked "Réapplication de 01-deployments.yaml" { kubectl apply -f $DeployFile -n $Namespace }

    Write-Host "Attente que Kafka soit prêt (jusqu'à 3min)..." -ForegroundColor DarkGray
    kubectl wait --for=condition=Ready pod -l app=kafka -n $Namespace --timeout=180s
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ATTENTION] Kafka n'est pas Ready après 3min -- vérifie manuellement : kubectl logs -l app=kafka -n $Namespace --previous" -ForegroundColor Yellow
    }

    Write-Step "4/5 -- Coup de pouce à schema-registry"
    Write-Host "(son backoff peut avoir expiré pendant qu'il attendait Kafka)" -ForegroundColor DarkGray
    kubectl delete pod -n $Namespace -l app=schema-registry --ignore-not-found
    Start-Sleep -Seconds 5

    Write-Step "5/5 -- État final"
    kubectl get pods -n $Namespace -o wide
    kubectl get pods -n monitoring -o wide

    Write-Host ""
    Write-Host "IP externes des nœuds :" -ForegroundColor Yellow
    kubectl get nodes -o wide
    Write-Host ""
    Write-Host "Étape suivante : bash scripts/test-nexshop-gke.sh (met à jour DuckDNS et l'issuer Keycloak)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Cluster démarré." -ForegroundColor Green
}

function Stop-NexshopCluster {
    Write-Step "1/2 -- Arrêt des node pools (1 -> 0), un par un"
    foreach ($pool in $NodePools) {
        Invoke-Checked "Resize $pool -> 0 nœud" {
            gcloud container clusters resize $Cluster --node-pool=$pool --num-nodes=0 --zone=$Zone --quiet
        }
    }

    Write-Step "2/2 -- Vérification"
    kubectl get nodes
    Write-Host ""
    Write-Host "Cluster arrêté (0 nœud sur les $($NodePools.Count) pools). Aucune facturation de calcul pendant cette pause." -ForegroundColor Green
    Write-Host "Relance 'scripts\restart_cluster.ps1 -Action start' pour reprendre -- le correctif Kafka est automatique." -ForegroundColor Green
}

switch ($Action) {
    "start" { Start-NexshopCluster }
    "stop"  { Stop-NexshopCluster }
}