# Semaine 4 : Observabilité, Monitoring & Benchmarking Avancé

L'objectif de la quatrième semaine est de garantir le suivi en temps réel de la santé de vos modèles et de mesurer précisément les performances.

# ✅ Semaine 4 bouclée (2026-09-16)

Tous les points ci-dessous ont été validés — détails complets dans [week-04-notes.md](week-04-notes.md).

- Prometheus (YAML brut, pas d'Operator/Helm) déployé, scrape vLLM et DCGM Exporter — les deux `up`. Service nommé `prometheus-k8s` pour matcher le trigger KEDA posé en semaine 3.
- DCGM Exporter en place (métriques GPU réelles : util, mémoire, température) après un détour sur un bug de device nodes cassés (`/dev/cpu/*/cpuid`) côté nœud kind, qui touchait aussi `privileged: true` sur `vllm-server` — retiré des deux déploiements.
- Dashboard Grafana "vLLM + GPU" (8 panels : requêtes running/waiting, débit tok/s, TTFT, ITL, KV cache, GPU util/mémoire/température) provisionné par fichiers, vérifié de bout en bout jusqu'aux vraies métriques GPU.
- KEDA : le trigger Prometheus resté en échec depuis la semaine 3 est maintenant vert (`HPAActive=True`) — bloqueur résolu au passage : `APIService v1beta1.external.metrics.k8s.io` disparue, ré-appliquée via le même bundle KEDA.
- `scripts/benchmark.py` réécrit en balayage de charge concurrente (1 → 128 requêtes simultanées) : 0 échec, throughput agrégé plafonnant à ~750-770 tok/s (limite compute GPU), latence p95 dégradée à 55s sous forte charge. KV cache observée à 99.5% d'utilisation sous burst — le scheduler vLLM throttle l'admission (`num_requests_running` 128→15) plutôt que de crasher.
- Resource requests/limits GPU déjà en place depuis la semaine 3 ; ajout `nodeAffinity` + `toleration` sur `vllm-server` (surtout symbolique sur ce cluster mono-nœud — le vrai bénéfice viendra avec les node groups GPU dédiés d'EKS en semaine 5-6).

## Monitoring vLLM (Prometheus & Grafana)

Traquer les métriques exposées nativement par l'endpoint /metrics de vLLM :

- Time to First Token (TTFT).

- Inter-token Latency (ITL).

- GPU Memory Utilization (KV Cache % vs Model Weights).

- Queue size & Throughput (tokens/s).

Déployer un dashboard Grafana dédié pour la supervision du cluster vLLM et du GPU.

## Benchmarking sous Kubernetes

Adapter le script benchmark.py de votre dépôt pour exécuter des tests de charge distribués (utilisant des outils comme Locust ou vLLM benchmark client).

Évaluer les performances sous stress (calcul du throughput maximum et étude des limites d'OOM sur la KV Cache).

## Gestion Avancée des Ressources GPU & Tolérances

Définir précisément les limits / requests Kubernetes ([nvidia.com/gpu](https://nvidia.com/gpu)).

Mettre en place des Taints / Tolerations et des NodeAffinity pour isoler vos charges vLLM sur les nœuds équipés de GPU.