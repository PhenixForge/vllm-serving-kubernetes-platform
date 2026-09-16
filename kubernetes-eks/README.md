# kubernetes-eks/ — manifestes spécifiques à EKS

Ce dossier ne contient **que** ce qui diffère réellement de [`../kubernetes/`](../kubernetes/) (le setup `kind` local, semaines 3-5). Tout le reste — Grafana, KEDA, l'Ingress, les `NetworkPolicy`, le Service vLLM, les PVC, Prometheus — n'a rien de spécifique à `kind` et se réutilise **tel quel** sur EKS.

## Ce qui est ici, et pourquoi

| Fichier | Pourquoi une variante EKS |
|---|---|
| `deployment.yaml` (vLLM) | Sur `kind`, pas de `nvidia-container-runtime` : tout le passthrough GPU (mounts `hostPath` sur `/dev/nvidia*`, libs driver copiées à la main) était manuel. Sur EKS, l'AMI accélérée choisie par Karpenter (`amiFamily: AL2`, `terraform/karpenter.tf`) l'a déjà — plus besoin de rien de tout ça. `image:` pointe vers un registre réel (ECR) au lieu d'une image chargée localement dans `kind`. |
| `dcgm-exporter-deployment.yaml` | Même histoire, plus subtil : DCGM ne doit **jamais** demander `nvidia.com/gpu` en ressource (ça le mettrait en concurrence avec vLLM pour l'unique GPU d'un `g5.xlarge`) — vérifié que la version `kind` ne le fait pas non plus. Utilise la stratégie "envvar" (`NVIDIA_VISIBLE_DEVICES=all`) plutôt que les mounts manuels. |
| `configmap.yaml` | Retire `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0`, un contournement spécifique aux 8 Go *partagés* de la RTX 4060 locale — le `g5.xlarge` a 24 Go de VRAM dédiés (A10G), cette contrainte ne devrait plus s'appliquer. |
| `nvidia-device-plugin.yaml` | Version standard non patchée (upstream v0.20.0) — celle de `kind` était patchée pour compenser l'absence de `nvidia-container-runtime`. |
| `storageclass.yaml` | EKS n'a pas de StorageClass par défaut (contrairement à `kind`/local-path-provisioner) — sans ça, les PVC existants resteraient `Pending`. Marquée par défaut pour que `kubernetes/pvc.yaml` et `kubernetes/prometheus-pvc.yaml` restent utilisables sans modification. |

**Rien de tout ceci n'a été testé sur un vrai cluster EKS** (pas de credentials AWS sur cette machine au moment de l'écriture, cf. `terraform/README.md`) — écrit par raisonnement à partir de ce qui a été appris et vérifié sur `kind` (semaines 3-5), pas par observation directe. À confirmer/corriger au premier déploiement réel.

## Ordre de déploiement (une fois `terraform apply` fait)

```bash
aws eks update-kubeconfig --region <region> --name vllm-serving   # cf. output `configure_kubectl` de terraform/

# 1. StorageClass par défaut — avant tout le reste, les PVC en dépendent
kubectl apply -f kubernetes-eks/storageclass.yaml

# 2. Device plugin GPU — avant vLLM/DCGM, qui en dépendent pour voir le GPU
kubectl apply -f kubernetes-eks/nvidia-device-plugin.yaml

# 3. Build + push l'image vLLM vers ECR (pas fait par ces manifestes)
docker build -t <ECR_REPO_URI>:latest -f container/Containerfile .
docker push <ECR_REPO_URI>:latest
# puis éditer kubernetes-eks/deployment.yaml : remplacer <ECR_REPO_URI> par la vraie URI

# 4. Namespaces + composants partagés (identiques à kind, aucune modification)
kubectl create namespace vllm
kubectl apply -f kubernetes/pvc.yaml
kubectl apply -f kubernetes-eks/configmap.yaml
kubectl apply -f kubernetes-eks/deployment.yaml
kubectl apply -f kubernetes/service.yaml

# 5. Monitoring (identique à kind, sauf dcgm-exporter-deployment.yaml)
kubectl apply -f kubernetes/monitoring-namespace.yaml
kubectl apply -f kubernetes/prometheus-configmap.yaml -f kubernetes/prometheus-pvc.yaml -f kubernetes/prometheus-deployment.yaml -f kubernetes/prometheus-service.yaml
kubectl apply -f kubernetes-eks/dcgm-exporter-deployment.yaml -f kubernetes/dcgm-exporter-service.yaml
kubectl apply -f kubernetes/grafana-datasource-configmap.yaml -f kubernetes/grafana-dashboard-provider-configmap.yaml -f kubernetes/grafana-dashboard-json-configmap.yaml -f kubernetes/grafana-deployment.yaml -f kubernetes/grafana-service.yaml

# 6. KEDA (contrôleur — pas encore un helm_release Terraform, même bundle YAML qu'en semaine 3)
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.20.2/keda-2.20.2.yaml
kubectl apply -f kubernetes/keda-scaledobject.yaml

# 7. Ingress-nginx (contrôleur — même bundle upstream qu'en semaine 3, pas encore en Terraform)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/aws/deploy.yaml
# recréer le secret Basic Auth (semaine 5) — jamais commité, généré à la main :
#   kubectl -n vllm create secret generic vllm-basic-auth --from-file=auth=<htpasswd>
kubectl apply -f kubernetes/ingress.yaml
# kubernetes/ingress.yaml référence encore host: vllm.local — remplacer par un vrai
# FQDN + Route 53 pour un usage au-delà d'un test (cf. docs/week-03-notes.md).

# 8. NetworkPolicy — write once en semaine 5, inertes sur kind, RÉELLEMENT appliquées ici
kubectl apply -f kubernetes/network-policy.yaml
```

## Pas encore fait

- KEDA et ingress-nginx installés en `kubectl apply` d'un bundle upstream (même méthode qu'en semaine 3 sur `kind`, pas de Helm requis) plutôt qu'en `helm_release` Terraform comme Karpenter — pourrait être unifié plus tard.
- `--max-model-len` / `--gpu-memory-utilization`, figés dans `container/Containerfile` pour les 8 Go partagés de la RTX 4060, ne sont pas reconsidérés pour les 24 Go dédiés du A10G — nécessiterait de reconstruire l'image, pas fait cette session.
