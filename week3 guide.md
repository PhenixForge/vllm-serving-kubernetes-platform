# Semaine 3 : Auto-scaling, Ingress & Gestion de Charge

L'objectif de cette semaine est de passer d'un simple déploiement statique à un service capable de supporter des variations de charge tout en assurant une exposition réseau sécurisée.
## Exposition via Ingress / Gateway API

Configurer un Ingress Controller (ex: NGINX Ingress ou Traefik) avec terminaison TLS/SSL.

Mettre en place un load balancing adapté au streaming de tokens (support de HTTP/2 / Server-Sent Events).

## Auto-scaling Horizontal (HPA / KEDA)

Configurer un HPA (Horizontal Pod Autoscaler) basé sur des métriques personnalisées (ex. longueur de la file d'attente vLLM, utilisation mémoire de la KV Cache).

Intégrer KEDA si vous souhaitez un auto-scaling directement couplé à Prometheus (évite d'augmenter le nombre de pods inutilement sur une simple charge CPU).

## Gestion du Cache & Persistent Volumes (PVC)

Configurer un stockage partagé performant ou un système de cache réseau (ex. ReadWriteMany via NFS/Ceph ou caching local par nœud) pour éviter le téléchargement répété des poids de modèles Hugging Face lors du spawn de nouveaux Pods.