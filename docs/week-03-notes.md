# Week 03 — Notes

Cluster local : `kind` (nom `vllm-cluster`), provider **podman** (`KIND_EXPERIMENTAL_PROVIDER=podman`), créé via `kind create cluster --name vllm-cluster` (voir [week2 guide.md](week2%20guide.md)) — pas de config GPU à la création.

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

### Couper le cluster (sans le détruire)

Pour libérer les ressources (CPU/RAM/GPU) quand on ne travaille pas dessus, sans perdre l'état (namespaces, PVC, manifestes appliqués) :

```bash
podman stop vllm-cluster-control-plane
podman ps -a --filter name=vllm-cluster   # doit passer en "Exited"
```

Pour reprendre ensuite, revenir aux étapes 2-4 ci-dessus (`podman start` + `kind export kubeconfig` + `kubectl get nodes`).

⚠️ Ne pas confondre avec `kind delete cluster` (détruit tout l'état, voir plus bas) — `podman stop` est réversible et sans risque, à utiliser librement entre deux sessions.

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

> ✅ **Validée end-to-end le 2026-09-14** — inférence réelle sur la RTX 4060 confirmée par un appel `/v1/completions` réussi depuis un pod kind (voir résultat en bas de section). La recherche initiale supposait que le trio CDI + podman + kind gérerait le gros du travail automatiquement ; en pratique il a fallu tout reproduire à la main (devices **et** bibliothèques driver **et** sur le pod applicatif, pas seulement sur le device-plugin) car ce cluster n'a pas de `nvidia-container-runtime`. Détails exacts ci-dessous.

### Étape 1 — Recréer le cluster avec les device nodes GPU + libs driver montés

Les conteneurs de nœuds kind tournent privilégiés : un bind-mount des fichiers de device NVIDIA suffit à leur donner l'accès matériel. Il faut **aussi** monter les bibliothèques userspace du driver (`libcuda.so.1`, `libnvidia-ml.so.1`) quelque part dans le nœud — sans `nvidia-container-runtime` pour les injecter automatiquement, il n'y a pas d'autre source pour ces `.so` à l'intérieur des conteneurs.

Config utilisée, commitée dans le repo : [`kind-gpu-config.yaml`](../kind-gpu-config.yaml).

Préparer d'abord un dossier de stage avec les bibliothèques et `nvidia-smi` (noms `.so.1` exacts, pas de symlink relatif qui pourrait casser au montage) :

```bash
mkdir -p ~/.cache/kind-nvidia-libs
cp -L /usr/lib64/libcuda.so.<VERSION> ~/.cache/kind-nvidia-libs/libcuda.so.1
cp -L /usr/lib64/libnvidia-ml.so.<VERSION> ~/.cache/kind-nvidia-libs/libnvidia-ml.so.1
cp -L /usr/bin/nvidia-smi ~/.cache/kind-nvidia-libs/nvidia-smi
chmod +x ~/.cache/kind-nvidia-libs/nvidia-smi
# <VERSION> = nvidia-smi --query-gpu=driver_version --format=csv,noheader (610.57.04 au moment du test)
```

`kind-gpu-config.yaml` monte ces devices + ce dossier (`/opt/nvidia-libs`, point neutre pour ne pas écraser les libs système du nœud) :

```bash
# Détruire l'ancien cluster (sans GPU) et en recréer un avec cette config
# ⚠️ Commande destructrice — l'utilisateur la lance lui-même, jamais l'assistant.
KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name vllm-cluster
KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --name vllm-cluster --config kind-gpu-config.yaml
```

### Étape 2 — Vérifier l'accès GPU depuis l'intérieur du nœud

```bash
podman exec vllm-cluster-control-plane ls -la /dev/nvidia* /opt/nvidia-libs
podman exec -e LD_LIBRARY_PATH=/opt/nvidia-libs vllm-cluster-control-plane /opt/nvidia-libs/nvidia-smi -L
# doit afficher : GPU 0: NVIDIA GeForce RTX 4060 (UUID: ...)
```

Confirmé fonctionnel avant même de toucher à Kubernetes — si ça échoue ici, inutile d'aller plus loin, le problème est dans le montage kind, pas dans k8s.

### Étape 3 — Déployer le NVIDIA k8s-device-plugin (patché)

Le manifeste officiel (`nvidia-device-plugin.yml` v0.14.5) suffit à faire apparaître `nvidia.com/gpu` dans les ressources du nœud, **mais** son pod doit lui aussi accéder aux devices + `libnvidia-ml.so` pour interroger NVML — mêmes montages manuels que l'étape 1, plus `securityContext.privileged: true` (pas de `nvidia-container-runtime` pour gérer les règles cgroup automatiquement) :

```yaml
# Ajouts par rapport au manifeste officiel NVIDIA/k8s-device-plugin v0.14.5 :
env:
  - name: LD_LIBRARY_PATH
    value: /opt/nvidia-libs
securityContext:
  privileged: true
volumeMounts:
  - {name: nvidia-libs, mountPath: /opt/nvidia-libs, readOnly: true}
  - {name: dev-nvidia, mountPath: /dev/nvidia0}
  - {name: dev-nvidiactl, mountPath: /dev/nvidiactl}
  - {name: dev-nvidia-uvm, mountPath: /dev/nvidia-uvm}
  - {name: dev-nvidia-uvm-tools, mountPath: /dev/nvidia-uvm-tools}
volumes:
  - {name: nvidia-libs, hostPath: {path: /opt/nvidia-libs}}
  - {name: dev-nvidia, hostPath: {path: /dev/nvidia0}}
  - {name: dev-nvidiactl, hostPath: {path: /dev/nvidiactl}}
  - {name: dev-nvidia-uvm, hostPath: {path: /dev/nvidia-uvm}}
  - {name: dev-nvidia-uvm-tools, hostPath: {path: /dev/nvidia-uvm-tools}}
```

```bash
kubectl apply -f nvidia-device-plugin-patched.yml
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds
# doit contenir : "Detected NVML platform: found NVML library"
```

### Étape 4 — Vérifier que le nœud annonce bien la ressource GPU

```bash
kubectl describe node vllm-cluster-control-plane | grep -A6 "Allocatable:"
# nvidia.com/gpu: 1   ← confirmé
```

### Étape 5 — Répéter le même montage manuel sur le Deployment applicatif

**Point non anticipé lors de la première rédaction de cette procédure** : le device plugin officiel utilise la stratégie `deviceListStrategy: envvar` — il se contente de poser `NVIDIA_VISIBLE_DEVICES=<uuid>` sur le pod qui demande `nvidia.com/gpu`, en supposant que `nvidia-container-runtime` interceptera cette variable pour injecter devices + libs. Sans ce runtime, la variable ne fait rien : **chaque pod applicatif qui a besoin du GPU doit reproduire exactement les mêmes montages manuels que l'étape 3** (devices + `/opt/nvidia-libs` + `LD_LIBRARY_PATH` + `privileged: true`), en plus de la requête `resources.limits."nvidia.com/gpu"` normale. C'est fait dans `kubernetes/deployment.yaml` (section `vllm` container).

### Résultat du test end-to-end (2026-09-14)

Après les étapes 1-5, le pod `vllm-server` charge le modèle sur GPU (logs : `device_config=cuda`, poids chargés, CUDA graphs compilés) et répond à une vraie requête d'inférence via le Service :

```bash
$ curl -s -X POST http://localhost:18000/v1/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "TheBloke/Mistral-7B-Instruct-v0.1-AWQ", "prompt": "Kubernetes is", "max_tokens": 20}'
{"choices":[{"text":" a powerful platform automation tool that allows you to deploy, scale, and manage containerized applications in", ...}], "usage": {"prompt_tokens":4,"completion_tokens":20,...}}
```

**Écueil rencontré en cours de route, sans rapport avec le GPU passthrough** : premier essai en `CrashLoopBackOff` avec `ValueError: No available memory for the cache blocks` — le budget `--gpu-memory-utilization=0.6` (figé dans l'image, RTX 4060 8 Go déjà partagée avec le bureau, ~1.9 Go utilisés hors vLLM) ne laisse plus de marge pour le KV cache une fois le profiling mémoire des CUDA graphs pris en compte (comportement par défaut depuis vLLM v0.21). Fix sans rebuild d'image : ajouter `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS: "0"` dans `kubernetes/configmap.yaml`.

`/v1/chat/completions` renvoie une erreur 400 séparée ("no chat template") — problème de configuration applicative du tokenizer, sans lien avec l'infra GPU/k8s, laissé de côté pour l'instant (`/v1/completions` suffit à valider le passthrough).

**Note technique — charger une image locale podman dans kind** : `kind load docker-image` échoue avec le provider podman (`"image not present locally"`, même si `podman images` la montre). La méthode qui fonctionne :

```bash
podman save -o ~/.cache/kind-image-load/<image>.tar localhost/<image>:latest
KIND_EXPERIMENTAL_PROVIDER=podman kind load image-archive ~/.cache/kind-image-load/<image>.tar --name vllm-cluster
rm ~/.cache/kind-image-load/<image>.tar
```

⚠️ L'image fait ~23 Go : ne pas passer par `/tmp` s'il est en tmpfs (RAM) — `df -h /tmp` avant, sinon `disk quota exceeded` en cours de `podman save`. Écrire dans un dossier sous `/home` (ex. `~/.cache/kind-image-load/`).

**Rappel important** : recréer le cluster (`kind delete` + `kind create`) efface tout son état (namespaces, PVC, pods). Après l'étape 1, il faut réappliquer `namespace vllm` + `pvc.yaml` + `configmap.yaml` + `service.yaml` + `deployment.yaml`, et **recharger l'image** (`kind load image-archive`) puisque le nouveau nœud ne l'a jamais vue.

---

## Autres points ouverts semaine 3 (rappel)

- ✅ GPU passthrough — fait (voir ci-dessus), `nvidia.com/gpu` réactivé dans `kubernetes/deployment.yaml`.
- FQDN `vllm.local` dans `kubernetes/ingress.yaml` : pas besoin de Route 53 tant qu'on reste sur kind local — juste une entrée `/etc/hosts`. Route 53 ne devient pertinent qu'à la migration EKS (semaine 5-6).
- Dépendance KEDA → Prometheus (`kubernetes/keda-scaledobject.yaml`) : décision prise d'attendre la stack Prometheus de la semaine 4 plutôt que déployer un Prometheus minimal jetable maintenant. KEDA lui-même (le contrôleur, via Helm) n'est pas encore installé dans le cluster.
- Pas de contrôleur Ingress (`ingress-nginx`) installé sur ce cluster kind — à faire avant de pouvoir tester le streaming via `curl -N http://vllm.local/...`.
- Erreur 400 sur `/v1/chat/completions` (pas de chat template par défaut pour ce tokenizer) — problème applicatif distinct, pas bloquant pour la validation infra.

---

## ✅ Validation Semaine 3 bouclée (2026-09-15)

`ingress-nginx` (contrôleur) et `keda` (opérateur) ont été installés entre-temps (bundle YAML officiel, sans Helm — indisponible sur cette machine, cf. plus haut). Restait à appliquer les manifestes applicatifs et valider le streaming end-to-end.

### Reprise de session : redémarrer le cluster arrêté

```bash
podman start vllm-cluster-control-plane
export KUBECONFIG=/tmp/vllm-kubeconfig
KIND_EXPERIMENTAL_PROVIDER=podman kind export kubeconfig --name vllm-cluster --kubeconfig "$KUBECONFIG"
```

### Bloqueur rencontré au redémarrage : `ingress-nginx` en CrashLoopBackOff permanent

Après redémarrage du conteneur, `ingress-nginx-controller` tournait déjà depuis 16h avec **56 redémarrages**, `keda-operator` avec **63 redémarrages**. Logs :

```
2026/09/15 21:32:12 [alert] 49#49: pthread_create() failed (11: Resource temporarily unavailable)
2026/09/15 21:32:12 [alert] 35#35: worker process 42 exited with fatal code 2 and cannot be respawned
```

```
ERROR scaleclient not able to get Kubernetes version {"error": "... dial tcp 10.96.0.1:443: connect: no route to host"}
```

**Cause identifiée** : en kind, **tous** les pods du cluster (kubelet, containerd, coredns, vLLM, ingress-nginx, KEDA…) tournent à l'intérieur d'un seul conteneur podman "nœud", qui partage un **unique cgroup `pids`** :

```bash
podman inspect vllm-cluster-control-plane --format '{{.HostConfig.PidsLimit}}'   # 2048
```

vLLM (runtime CUDA multi-thread) + tous les composants système consomment une bonne part de ce budget partagé de 2048 PIDs/threads ; nginx qui tente de spawn ses worker threads se heurte par intermittence à `EAGAIN`. Même famille de problème que l'écueil inotify documenté plus haut (une limite système partagée entre trop de monde), mais sur le compteur `pids` cette fois.

**Fix appliqué, à chaud, sans recréer le cluster** :

```bash
podman update --pids-limit 8192 vllm-cluster-control-plane
kubectl delete pod -n ingress-nginx -l app.kubernetes.io/component=controller   # relance avec la nouvelle limite
```

Résultat : `ingress-nginx-controller` stable en `1/1 Running` après 2 redémarrages au lieu de crashlooper en continu. `keda-operator`/`keda-admission`/`keda-metrics-apiserver` se sont aussi stabilisés à `1/1` (leur erreur `no route to host` était liée au même redémarrage du CNI, résolue une fois le nœud stabilisé).

> Si ça revient sur une prochaine recréation du cluster : soit relancer cette commande `podman update` après chaque `kind create cluster`, soit ajouter le pids-limit directement dans une future config kind si l'option existe côté containerd.

**Pods `vllm-server` fantômes** : après le redémarrage, 2 anciens pods étaient bloqués en `UnexpectedAdmissionError` (`no healthy devices present` — le device-plugin GPU venait de se ré-enregistrer). Le nouveau pod créé par le ReplicaSet, lui, est reparti sain. Nettoyage :

```bash
kubectl delete pod -n vllm vllm-server-868c74994c-8c4dr vllm-server-868c74994c-hlwc9
```

### Déploiement des manifestes restants

```bash
kubectl apply -f kubernetes/ingress.yaml
kubectl apply -f kubernetes/keda-scaledobject.yaml
```

- `ingress.yaml` : accepté avec un warning (annotation `kubernetes.io/ingress.class` dépréciée au profit de `spec.ingressClassName` — à migrer un jour, non bloquant, ingress-nginx la respecte encore).
- `keda-scaledobject.yaml` : `ScaledObjectReady=True` côté KEDA, mais `KEDAScalerFailed` en boucle sur `prometheus-k8s.monitoring.svc.cluster.local: no such host` — **attendu**, cf. décision ci-dessus d'attendre la stack Prometheus semaine 4.

### ✅ Test streaming via Ingress — validé

Pas d'`extraPortMappings` 80/443 dans `kind-gpu-config.yaml` (seul 6443 est exposé côté host), donc test via `kubectl port-forward` plutôt que directement sur `vllm.local` :

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80
curl -N -H "Host: vllm.local" http://localhost:18080/v1/completions \
  -X POST -H "Content-Type: application/json" \
  -d '{"model": "TheBloke/Mistral-7B-Instruct-v0.1-AWQ", "prompt": "Kubernetes is", "max_tokens": 15, "stream": true}'
```

Résultat : flux SSE token par token (`data: {...}` par token, terminé par `data: [DONE]`), confirmant que `proxy-buffering: off` fonctionne correctement à travers l'Ingress.

> Pour un test direct sur `http://vllm.local/...` sans port-forward, il faudrait ajouter `extraPortMappings` (80→80, 443→443) dans `kind-gpu-config.yaml` — nécessite de recréer le cluster, laissé pour une prochaine session (⚠️ recréation du cluster : à lancer soi-même, pas par l'assistant).

**Semaine 3 : tous les objectifs sont maintenant validés** — Ingress + streaming SSE, HPA/KEDA installé et fonctionnel (bloqué uniquement sur la donnée Prometheus, dépendance semaine 4 assumée), PVC/cache déjà en place depuis les notes précédentes.
