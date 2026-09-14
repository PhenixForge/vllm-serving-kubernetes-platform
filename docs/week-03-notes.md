# Week 03 — Notes

Cluster local : `kind` (nom `vllm-cluster`), provider **podman** (`KIND_EXPERIMENTAL_PROVIDER=podman`), créé via `kind create cluster --name vllm-cluster` (voir [week2 guide.md](../week2%20guide.md)) — pas de config GPU à la création.

---

## Démarrer et vérifier le cluster kind (procédure qui fonctionne)

Le cluster n'est pas détruit entre deux sessions, mais son conteneur podman peut être arrêté (redémarrage machine, etc.) :

```bash
# 1. Vérifier l'état du conteneur du control-plane
podman ps -a --filter name=vllm-cluster

# 2. S'il est "Exited", le redémarrer (ne recrée pas le cluster, réutilise son état)
podman start vllm-cluster-control-plane

# 3. Régénérer un kubeconfig pointant dessus (le port 6443 mappé peut changer d'IP après redémarrage)
export KUBECONFIG=/tmp/vllm-kubeconfig   # ou ~/.kube/config si tu veux le rendre permanent
KIND_EXPERIMENTAL_PROVIDER=podman kind export kubeconfig --name vllm-cluster --kubeconfig "$KUBECONFIG"

# 4. Vérifier que l'API server répond (peut prendre quelques secondes après le start)
kubectl get nodes
```

Sortie attendue à l'étape 4 :

```
NAME                         STATUS   ROLES           AGE   VERSION
vllm-cluster-control-plane   Ready    control-plane   ...   v1.30.0
```

Lister les clusters kind connus par l'outil (utile si le nom est oublié) :

```bash
KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters
```

---

## Déployer les manifestes semaine 3

```bash
cd vllm-serving-kubernetes-platform
kubectl create namespace vllm        # si pas déjà créé
kubectl apply -f kubernetes/pvc.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl get pods -n vllm -o wide
```

Le PVC reste `Pending` tant qu'aucun pod n'est planifié — normal, la storage class `standard` (`rancher.io/local-path`) est en `WaitForFirstConsumer`, elle se lie dès que le pod passe en scheduling.

---

## Bloqueur constaté (2026-09-14) : pas de GPU dans kind

`kubectl describe node vllm-cluster-control-plane` ne montre aucune ressource `nvidia.com/gpu` en Capacity/Allocatable → le pod `vllm-server` reste `Pending` :

```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient nvidia.com/gpu.
```

Ce cluster a été créé sans passthrough GPU. Le host, lui, a bien accès au GPU (vérifié) :

```bash
$ nvidia-smi -L
GPU 0: NVIDIA GeForce RTX 4060 (UUID: GPU-7a4bd667-88bd-7172-28ba-fd8f4bf55a3f)
$ nvidia-smi --query-gpu=driver_version --format=csv,noheader
610.57.04
```

Et podman sait déjà exposer ce GPU à un conteneur simple via CDI (c'est ce que fait `scripts/run-local.sh` avec `--device nvidia.com/gpu=all`) :

```bash
$ cat /etc/cdi/nvidia.yaml   # généré préalablement, présent sur cette machine
cdiVersion: "0.5.0"
kind: nvidia.com/gpu
...
devices:
  - name: all
    containerEdits:
      deviceNodes:
        - path: /dev/nvidia0
        - path: /dev/nvidiactl
        - path: /dev/nvidia-uvm
        - path: /dev/nvidia-uvm-tools
```

Le problème est que **kind ne relaie pas ce mécanisme CDI vers les conteneurs "nœuds"** qu'il crée lui-même — il faut le configurer explicitement.

---

## Procédure : GPU passthrough dans kind + NVIDIA k8s-device-plugin

> ⚠️ **Non encore validée end-to-end sur cette machine.** C'est la démarche standard documentée par NVIDIA/communauté pour kind (historiquement écrite pour le provider Docker). Le provider podman de kind est expérimental et cette combinaison précise (podman + CDI + kind) n'a pas de recette officielle garantie — à tester et ajuster. Documentée ici pour être reproductible, pas comme un résultat déjà obtenu.

### Étape 1 — Recréer le cluster avec les device nodes GPU montés

Les conteneurs de nœuds kind tournent en `--privileged` : un simple bind-mount des fichiers de device NVIDIA suffit à leur donner l'accès matériel (pas besoin que kind comprenne CDI lui-même). Recréer le cluster avec une config qui monte les devices :

```yaml
# kind-gpu-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
    - hostPath: /dev/nvidia0
      containerPath: /dev/nvidia0
    - hostPath: /dev/nvidiactl
      containerPath: /dev/nvidiactl
    - hostPath: /dev/nvidia-uvm
      containerPath: /dev/nvidia-uvm
    - hostPath: /dev/nvidia-uvm-tools
      containerPath: /dev/nvidia-uvm-tools
    # bibliothèques driver userspace (nécessaires à libnvidia-ml.so pour le device plugin)
    - hostPath: /usr/lib64/libnvidia-ml.so.610.57.04
      containerPath: /usr/lib64/libnvidia-ml.so.1
      readOnly: true
```

```bash
# Détruire l'ancien cluster (sans GPU) et en recréer un avec cette config
KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name vllm-cluster
KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --name vllm-cluster --config kind-gpu-config.yaml
```

**Attention** : `kind delete cluster` supprime l'état actuel du cluster (namespaces, workloads de test). À faire consciemment, pas par réflexe — vérifier avant qu'il n'y a rien à préserver dedans.

Adapter la version `610.57.04` du nom de fichier `libnvidia-ml.so.*` si le driver a été mis à jour depuis (`nvidia-smi --query-gpu=driver_version --format=csv,noheader` pour la valeur courante).

### Étape 2 — Vérifier l'accès GPU depuis l'intérieur du nœud

```bash
podman exec -it vllm-cluster-control-plane ls -la /dev/nvidia*
# doit lister les mêmes device nodes que sur le host
```

### Étape 3 — Déployer le NVIDIA k8s-device-plugin

Utiliser une version taguée (pas `main`) pour rester reproductible :

```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml
kubectl get pods -n kube-system | grep nvidia-device-plugin
```

### Étape 4 — Vérifier que le nœud annonce bien la ressource GPU

```bash
kubectl describe node vllm-cluster-control-plane | grep -A5 "Allocatable:"
# doit maintenant contenir : nvidia.com/gpu: 1
```

Si `nvidia.com/gpu` n'apparaît toujours pas : regarder les logs du pod `nvidia-device-plugin` (`kubectl logs -n kube-system <pod>`) — la cause la plus probable est que `libnvidia-ml.so` n'est pas trouvée dans le nœud (chemin/version à ajuster dans `extraMounts`).

### Étape 5 — Réactiver la requête GPU dans le Deployment

Une fois l'étape 4 validée, décommenter les lignes `nvidia.com/gpu` dans `kubernetes/deployment.yaml` (voir section suivante) et ré-appliquer.

---

## Solution temporaire adoptée (2026-09-14) — pas de GPU request

En attendant la procédure ci-dessus, les lignes `nvidia.com/gpu` de `kubernetes/deployment.yaml` sont **commentées** (pas supprimées) pour permettre au pod d'être planifié et de valider le reste du pipeline (Service, PVC binding, Ingress, KEDA) sans bloquer sur le scheduling.

Conséquence assumée : le conteneur vLLM n'aura pas d'accès GPU réel dans cet état — il est probable qu'il crash-loop à l'initialisation CUDA. C'est acceptable pour cette étape : l'objectif est de valider la tuyauterie Kubernetes, pas l'inférence, tant que le passthrough GPU n'est pas en place.

**Piste retenue pour la semaine 4** : au lieu de finir la procédure GPU-dans-kind maintenant, on progresse en parallèle sur les deux fronts qui convergent en semaine 4 — l'observabilité (Prometheus/Grafana, dépendance déjà notée pour KEDA) et le GPU passthrough kind décrit ci-dessus. Remettre `nvidia.com/gpu` en clair dans `deployment.yaml` dès que l'étape 4 de la procédure GPU est validée.

**Résultat observé (2026-09-14) avec ce workaround** : le pod se planifie et son image (`localhost/vllm-mistral-7b-v01:latest`, chargée via `podman save` + `kind load image-archive` — `kind load docker-image` a échoué avec le provider podman, voir note ci-dessous) démarre bien, mais crash immédiatement en `CrashLoopBackOff` :

```
RuntimeError: Failed to infer device type, please set the environment variable
`VLLM_LOGGING_LEVEL=DEBUG` to turn on verbose logging to help debug the issue.
```

Attendu et sans surprise : vLLM ne trouve aucun GPU. Ça confirme que la tuyauterie Kubernetes (scheduling, PVC binding, ConfigMap, Service) fonctionne ; seule l'inférence réelle attend le passthrough GPU.

**Note technique — charger une image locale podman dans kind** : `kind load docker-image` échoue avec le provider podman (`"image not present locally"`, même si `podman images` la montre). La méthode qui fonctionne :

```bash
podman save -o /home/<user>/.cache/kind-image-load/<image>.tar localhost/<image>:latest
KIND_EXPERIMENTAL_PROVIDER=podman kind load image-archive /home/<user>/.cache/kind-image-load/<image>.tar --name vllm-cluster
```

⚠️ L'image fait ~23 Go : ne pas passer par `/tmp` s'il est en tmpfs (RAM) — `df -h /tmp` avant, sinon `disk quota exceeded` en cours de `podman save`. Écrire dans un dossier sous `/home` (ex. `~/.cache/kind-image-load/`), et supprimer le tar après le `kind load` (pas besoin de le garder).

---

## Autres points ouverts semaine 3 (rappel)

- FQDN `vllm.local` dans `kubernetes/ingress.yaml` : pas besoin de Route 53 tant qu'on reste sur kind local — juste une entrée `/etc/hosts`. Route 53 ne devient pertinent qu'à la migration EKS (semaine 5-6).
- Dépendance KEDA → Prometheus (`kubernetes/keda-scaledobject.yaml`) : décision prise d'attendre la stack Prometheus de la semaine 4 plutôt que déployer un Prometheus minimal jetable maintenant.
- Pas de contrôleur Ingress (`ingress-nginx`) installé sur ce cluster kind — à faire avant de pouvoir tester le streaming via `curl -N http://vllm.local/...`.
