# Semaine 3 : Auto-scaling, Ingress & Gestion de Charge

L'objectif de cette semaine est de passer d'un simple déploiement statique à un service capable de supporter des variations de charge tout en assurant une exposition réseau sécurisée.
## Exposition via Ingress / Gateway API

Configurer un Ingress Controller (ex: NGINX Ingress ou Traefik) avec terminaison TLS/SSL.

Mettre en place un load balancing adapté au streaming de tokens (support de HTTP/2 / Server-Sent Events).

## Auto-scaling Horizontal (HPA / KEDA)

Configurer un HPA (Horizontal Pod Autoscaler) basé sur des métriques personnalisées (ex. longueur de la file d'attente vLLM, utilisation mémoire de la KV Cache).

Intégrer KEDA si vous souhaitez un auto-scaling directement couplé à Prometheus (évite d'augmenter le nombre de pods inutilement sur une simple charge CPU).

>[!NOTE]
**Une dépendance tranchée consciemment : KEDA vs Prometheus**.
Mon scaledobject pointe vers prometheus-k8s.monitoring.svc.cluster.local, qui n'existera que semaine 4 (stack Prometheus/Grafana). 

Deux options défendables : 
Déployer un Prometheus minimal dès maintenant juste pour scraper `/metrics` de vLLM et valider le scaler end-to-end en semaine 3 ; 

Sinon documenter explicitement que le manifest KEDA est écrit et relu, mais seulement testable une fois l'observabilité en place.

## Gestion du Cache & Persistent Volumes (PVC)

Configurer un stockage partagé performant ou un système de cache réseau (ex. ReadWriteMany via NFS/Ceph ou caching local par nœud) pour éviter le téléchargement répété des poids de modèles Hugging Face lors du spawn de nouveaux Pods.

---

# Reste à faire
## Finir la configuration du LB nginx `ingress.yaml`
Ajouter mon FQDN dedans.

## Étape 3 : Auto-scaling Horizontal (HPA & KEDA)

>[!NOTE]
>L'autoscaling sur CPU/RAM classique n'est pas adapté aux LLM. 

Il est préférable d'utiliser KEDA (Kubernetes Event-driven Autoscaling) basé sur les métriques Prometheus exposées par vLLM (ex. nombre de requêtes en attente).

### 3.1 Prérequis KEDA

Installez KEDA dans mon cluster via Helm (si manquant) :

```Bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
```

### 3.2 Vérifier l'état dans Prometheus

## Validation de la Semaine 3

Déployer les configurations :

```bash
kubectl apply -f kubernetes/pvc.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/ingress.yaml
kubectl apply -f kubernetes/keda-scaledobject.yaml
```

Tester le streaming Ingress :

```bash
curl -N http://vllm.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-name",
    "messages": [{"role": "user", "content": "Raconte une histoire."}],
    "stream": true
  }'
```

Vérifier l'autoscaler :

```bash
kubectl get scaledobject -n vllm
kubectl get hpa -n vllm
```