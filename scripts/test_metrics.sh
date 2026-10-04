#!/bin/bash
# Vérifie que les 22 métriques utilisées par le collecteur AIOps renvoient des données.
# Usage : NODE_IP=<IP externe d'un nœud> bash scripts/test_metrics.sh

NODE_IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')}"
PROM="http://${NODE_IP}:30090"
LOKI="http://${NODE_IP}:30003"
TEMPO="http://${NODE_IP}:30622"

echo "========================================"
echo "      TEST DES 22 METRIQUES"
echo "========================================"

##############################################
# Prometheus / Loki
##############################################

test_metric() {
    NAME="$1"
    URL="$2"

    RESULT=$(curl -sG "$URL" "${@:3}")

    if echo "$RESULT" | grep -q '"status":"success"'; then
        if echo "$RESULT" | grep -q '"result":\[\]'; then
            echo "[WARNING] $NAME : aucune donnée"
        else
            echo "[OK] $NAME"
        fi
    else
        echo "[ERROR] $NAME"
    fi
}

##############################################
# Tempo
##############################################

test_tempo_metric() {

    NAME="$1"
    QUERY="$2"

    RESULT=$(curl -sG "$TEMPO/api/search" \
        --data-urlencode "q=$QUERY")

    if echo "$RESULT" | grep -q '"traces"'; then

        if echo "$RESULT" | grep -q '"traces":\[\]'; then
            echo "[WARNING] $NAME : aucune trace"
        else
            echo "[OK] $NAME"
        fi

    else
        echo "[ERROR] $NAME"
    fi
}

##############################################
# PROMETHEUS
##############################################

echo
echo "========== PROMETHEUS =========="

test_metric "cpu_usage_pct" "$PROM/api/v1/query" \
--data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="nexshop",container!="",container!="POD"}[2m])) by (pod) / sum(kube_pod_container_resource_limits{namespace="nexshop",resource="cpu"}) by (pod) * 100'

test_metric "memory_usage_pct" "$PROM/api/v1/query" \
--data-urlencode 'query=sum(container_memory_working_set_bytes{namespace="nexshop",container!="",container!="POD"}) by (pod) / sum(kube_pod_container_resource_limits{namespace="nexshop",resource="memory"}) by (pod) * 100'

test_metric "memory_working_set_bytes" "$PROM/api/v1/query" \
--data-urlencode 'query=sum(container_memory_working_set_bytes{namespace="nexshop",container!="",container!="POD"}) by (pod)'

test_metric "restart_count_delta" "$PROM/api/v1/query" \
--data-urlencode 'query=sum(increase(kube_pod_container_status_restarts_total{namespace="nexshop"}[5m])) by (pod)'

test_metric "jvm_heap_used_pct" "$PROM/api/v1/query" \
--data-urlencode 'query=sum(jvm_memory_used_bytes{namespace="nexshop",area="heap"}) by (pod) / sum(jvm_memory_max_bytes{namespace="nexshop",area="heap"}) by (pod) * 100'

test_metric "gc_pause_total_sec" "$PROM/api/v1/query" \
--data-urlencode 'query=sum(rate(jvm_gc_pause_seconds_sum{namespace="nexshop"}[2m])) by (pod)'

test_metric "http_p95_latency_ms" "$PROM/api/v1/query" \
--data-urlencode 'query=histogram_quantile(0.95,sum(rate(http_server_requests_seconds_bucket{namespace="nexshop"}[2m])) by (le,pod))*1000'

test_metric "http_error_rate_pct" "$PROM/api/v1/query" \
--data-urlencode 'query=sum(rate(http_server_requests_seconds_count{namespace="nexshop",status=~"5.."}[5m])) by (pod) / sum(rate(http_server_requests_seconds_count{namespace="nexshop"}[5m])) by (pod) * 100'

test_metric "db_active_connections_mysql" "$PROM/api/v1/query" \
--data-urlencode 'query=hikaricp_connections_active{namespace="nexshop"}'

test_metric "db_active_connections_mongo" "$PROM/api/v1/query" \
--data-urlencode 'query=mongodb_driver_pool_checkedout{namespace="nexshop"}'

test_metric "db_query_duration_avg_ms" "$PROM/api/v1/query" \
--data-urlencode 'query=sum(rate(mongodb_driver_commands_seconds_sum{namespace="nexshop"}[5m])) by (pod) / sum(rate(mongodb_driver_commands_seconds_count{namespace="nexshop"}[5m])) by (pod) * 1000'

test_metric "db_query_duration_max_ms" "$PROM/api/v1/query" \
--data-urlencode 'query=max(max_over_time(mongodb_driver_commands_seconds_max{namespace="nexshop"}[5m])) by (pod) * 1000'

test_metric "node_cpu_usage_pct" "$PROM/api/v1/query" \
--data-urlencode 'query=100-(avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[2m]))*100)'

test_metric "node_load1" "$PROM/api/v1/query" \
--data-urlencode 'query=node_load1'

test_metric "node_memory_available_pct" "$PROM/api/v1/query" \
--data-urlencode 'query=node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes*100'

test_metric "waiting_reason" "$PROM/api/v1/query" \
--data-urlencode 'query=kube_pod_container_status_waiting_reason{namespace="nexshop"}==1'

test_metric "last_terminated_reason" "$PROM/api/v1/query" \
--data-urlencode 'query=kube_pod_container_status_last_terminated_reason{namespace="nexshop"}==1'

##############################################
# LOKI
##############################################

echo
echo "========== LOKI =========="

test_metric "log_error_count" "$LOKI/loki/api/v1/query" \
--data-urlencode 'query=sum(count_over_time({namespace="nexshop"} |~ "(?i)error"[5m])) by (pod)'

test_metric "log_warn_count" "$LOKI/loki/api/v1/query" \
--data-urlencode 'query=sum(count_over_time({namespace="nexshop"} |~ "(?i)warn"[5m])) by (pod)'

test_metric "log_volume_total" "$LOKI/loki/api/v1/query" \
--data-urlencode 'query=sum(count_over_time({namespace="nexshop"}[5m])) by (pod)'

##############################################
# TEMPO
##############################################

echo
echo "========== TEMPO =========="

test_tempo_metric \
"product_service_traces" \
'{resource.service.name="product-service"}'

test_tempo_metric \
"api_gateway_traces" \
'{resource.service.name="api-gateway"}'

##############################################

echo
echo "========================================"
echo "Tests terminés."
echo "========================================"
