# Semaine 4 : Observabilité, Monitoring & Benchmarking Avancé

L'objectif de la quatrième semaine est de garantir le suivi en temps réel de la santé de vos modèles et de mesurer précisément les performances.

    ## Monitoring vLLM (Prometheus & Grafana)

        Traquer les métriques exposées nativement par l'endpoint /metrics de vLLM :

            Time to First Token (TTFT).

            Inter-token Latency (ITL).

            GPU Memory Utilization (KV Cache % vs Model Weights).

            Queue size & Throughput (tokens/s).

        Déployer un dashboard Grafana dédié pour la supervision du cluster vLLM et du GPU.

    ## Benchmarking sous Kubernetes

        Adapter le script benchmark.py de votre dépôt pour exécuter des tests de charge distribués (utilisant des outils comme Locust ou vLLM benchmark client).

        Évaluer les performances sous stress (calcul du throughput maximum et étude des limites d'OOM sur la KV Cache).

    ## Gestion Avancée des Ressources GPU & Tolérances

        Définir précisément les limits / requests Kubernetes ([nvidia.com/gpu](https://nvidia.com/gpu)).

        Mettre en place des Taints / Tolerations et des NodeAffinity pour isoler vos charges vLLM sur les nœuds équipés de GPU.