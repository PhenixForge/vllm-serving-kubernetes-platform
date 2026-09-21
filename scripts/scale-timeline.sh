#!/usr/bin/env bash
# Horodate les étapes d'un scale-out (semaine 7) : réplicas, NodeClaims Karpenter,
# nœuds GPU, état des pods vLLM. Une ligne CSV à chaque CHANGEMENT d'état, en UTC,
# à croiser avec les fenêtres de scripts/benchmark.py --duration (mêmes horloges).
#
# Usage : scripts/scale-timeline.sh [intervalle_s] > timeline.csv
# Prérequis : kubectl configuré sur le cluster EKS ; lecture seule (aucune écriture).
# Résultat attendu, dans l'ordre : hpa desired>1 -> nodeclaim créé -> node Ready
# -> pod ContainerCreating -> pod Running -> pod Ready. Les écarts entre ces
# lignes SONT le cold start à documenter (docs/week7 guide.md).
set -euo pipefail
INTERVAL="${1:-5}"
NS="${VLLM_NAMESPACE:-vllm}"
prev=""
echo "time_utc,hpa_desired,hpa_current,nodeclaims,gpu_nodes_ready,vllm_pods(name:phase:ready)"
while true; do
  now="$(date -u +%H:%M:%SZ)"
  hpa="$(kubectl -n "$NS" get hpa -o jsonpath='{range .items[*]}{.status.desiredReplicas},{.status.currentReplicas}{end}' 2>/dev/null || echo ',')"
  claims="$(kubectl get nodeclaims.karpenter.sh --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  nodes="$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  pods="$(kubectl -n "$NS" get pods -l app=vllm-server -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}:{range .status.conditions[?(@.type=="Ready")]}{.status}{end};{end}' 2>/dev/null || true)"
  state="$hpa|$claims|$nodes|$pods"
  if [[ "$state" != "$prev" ]]; then
    echo "$now,$hpa,$claims,$nodes,$pods"
    prev="$state"
  fi
  sleep "$INTERVAL"
done
