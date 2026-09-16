# Week 04 — Notes

## Reprise de session : redémarrer le cluster arrêté

Même procédure qu'en semaine 3 :

```bash
podman start vllm-cluster-control-plane
export KUBECONFIG=/tmp/vllm-kubeconfig
KIND_EXPERIMENTAL_PROVIDER=podman kind export kubeconfig --name vllm-cluster --kubeconfig "$KUBECONFIG"
```

Au redémarrage, mêmes symptômes transitoires que la semaine passée : `kubectl get nodes` a renvoyé un `Forbidden` sur `kubernetes-admin` pendant quelques secondes (API server encore en train de démarrer), résolu tout seul au retry. Et un pod `vllm-server` fantôme en `UnexpectedAdmissionError` (device-plugin GPU qui se ré-enregistre) — nettoyé avec `kubectl delete pod`.

---

## Prometheus (sans Operator, sans Helm)

Toujours pas de Helm sur cette machine (cf. semaine 3). Plutôt qu'un `kube-prometheus-stack`, déploiement d'un Prometheus "nu" en YAML brut : `kubernetes/monitoring-namespace.yaml`, `prometheus-configmap.yaml` (scrape config), `prometheus-pvc.yaml`, `prometheus-deployment.yaml`, `prometheus-service.yaml`.

Le nom du Service est figé à **`prometheus-k8s`** (port 9090, namespace `monitoring`) : c'est exactement le `serverAddress` que le KEDA `ScaledObject` de la semaine 3 attendait déjà (`prometheus-k8s.monitoring.svc.cluster.local:9090`) — pas besoin d'y retoucher.

Cibles en `static_configs` plutôt qu'en `kubernetes_sd_configs` : pour un lab mono-namespace, ça évite d'avoir à donner à Prometheus un ServiceAccount + RBAC sur l'API Kubernetes juste pour de la découverte de service.

### Bloqueur : mauvais nom de Service pour vLLM

Premier essai de scrape avec `vllm-server.vllm.svc.cluster.local:8000` → `no such host`. En fait le Service s'appelle `vllm-service` (le nom `vllm-server` est celui du Deployment/des pods, pas du Service — confusion facile). Corrigé dans `prometheus-configmap.yaml`.

### KEDA a besoin d'un label `namespace` que vLLM n'expose pas

La query du `ScaledObject` (`sum(vllm:num_requests_waiting{namespace="vllm"})`) suppose un label `namespace` sur la métrique. Les métriques natives de vLLM n'exposent que `engine` et `model_name` — pas de `namespace` (normal, vLLM ne sait rien de Kubernetes). Avec du service discovery K8s ce label serait ajouté automatiquement par Prometheus ; en `static_configs`, il faut le poser à la main via `labels:` sur la cible.

### Bloqueur : RollingUpdate + PVC RWO local-path = lock TSDB

Un premier `kubectl apply` du ConfigMap corrigé + `rollout restart` a fait planter le nouveau pod : `opening storage failed: lock DB directory: resource temporarily unavailable`. Cause : la stratégie par défaut du Deployment (`RollingUpdate`) crée le nouveau pod *avant* de tuer l'ancien ; les deux se partagent le même PVC `ReadWriteOnce` (provisionné par `local-path`, donc lié au nœud) et se disputent le lockfile TSDB de Prometheus. Fix : `strategy.type: Recreate` sur le Deployment — acceptable ici (une seule replica, un peu de downtime de collecte n'est pas critique dans ce lab).

### Résultat

```
job=vllm            health=up
job=prometheus      health=up
```

Query `sum(vllm:num_requests_waiting{namespace="vllm"})` → `0` (idle, comme attendu).

## KEDA : le trigger Prometheus, enfin vert

Avant de commencer le monitoring, `keda-operator` était reparti en `CrashLoopBackOff` avec la même erreur `couldn't initialize inotify: too many open files` que la semaine 3 (`fs.inotify.max_user_instances`, limite host partagée avec le bureau GNOME, saturée à 128/128). Le fix de la semaine 3 (`sysctl -w`) n'était pas persistant — reperdu au reboot. Cette fois, fixé pour de bon dans `/etc/sysctl.d/99-inotify-kind.conf` (`max_user_instances = 1024`), appliqué par l'utilisateur lui-même (sudo).

Une fois `keda-operator` relancé, la ScaledObject restait bloquée : `HPAActive=False`, `unable to get external metric ... the server could not find the requested resource (get s0-prometheus.external.metrics.k8s.io)`. Diagnostic : l'`APIService v1beta1.external.metrics.k8s.io` (couche d'agrégation qui expose les métriques KEDA à l'API Kubernetes) avait complètement disparu — probablement perdu pendant le chaos de crashloop de la semaine 3 (inotify + pids-limit combinés). Ré-appliqué le même bundle KEDA qu'en semaine 3 (`kubectl apply --server-side -f .../keda-2.20.2.yaml`, idempotent) → l'APIService a été recréée.

**Résultat : `HPAActive=True`, `keda-hpa-vllm-autoscaler` lit désormais une vraie valeur Prometheus (`0/5 (avg)`).** L'item resté en suspens depuis la semaine 3 (scaler Prometheus qui échouait en boucle sur `no such host`) est maintenant résolu.

---

## DCGM Exporter (métriques GPU)

`kubernetes/dcgm-exporter-deployment.yaml` + `dcgm-exporter-service.yaml`, namespace `monitoring`, image `nvcr.io/nvidia/k8s/dcgm-exporter:latest` (tag non épinglé — pas de recherche web disponible dans cette session pour vérifier un tag précis existant ; à figer plus tard).

### Bloqueur 1 : `privileged: true` casse le démarrage du conteneur

Copié le pattern `privileged: true` + mounts `/dev/nvidia*` de vLLM tel quel → `OCI runtime create failed ... error creating device nodes: mount /dev/cpu/1/cpuid ... no such file or directory`. En mode privileged, runc essaie de mirrorer *tous* les devices du nœud (dcgm-exporter a un vrai usage légitime de `/dev/cpu/*/cpuid` : option `--cpu-devices` pour le monitoring CPU sur les plateformes NVIDIA Grace). Le nœud kind a bien un `/dev/cpu/1/cpuid`, mais avec un mode cassé (`c---------`, owner `nobody:nogroup`) → `podman exec vllm-cluster-control-plane ls -la /dev/cpu/1/`.

**Fix** : pas besoin de `privileged` ici, seulement de NVML. Remplacé par `securityContext.capabilities.add: [SYS_ADMIN]`, en gardant les mounts `/dev/nvidia*` explicites (ceux-là n'ont pas besoin du mode privileged pour être mappés, contrairement au mirroring automatique).

### Bloqueur 2 : erreur "exit status 1" sans aucun détail

Même avec le fix ci-dessus, le conteneur crashait immédiatement avec pour seul log `Starting dcgm-exporter` puis `exit status 1`. Image quasi-distroless (`/usr/bin/` contient à peine `bash`, `sh`, `env`, `sleep`, `dcgm-exporter` — pas de `ls`, `cat`, `curl`, `find`). Débogage via `kubectl patch --type=json` sur `command` (`["sleep","3600"]` — **pas** `"infinity"`, le binaire `sleep` de cette image est un utilitaire maison qui ne le supporte pas et sort en erreur silencieuse) pour garder un pod vivant, puis `bash -c 'echo "$(< file)"'` (pas de `cat`) pour lire l'entrypoint et `[ -r ]`/`[ -w ]` pour tester les permissions des devices (pas de `ls`/`stat`).

Confirmé : UID 0, devices `/dev/nvidia*` en RW, lib NVML lisible, `LD_LIBRARY_PATH` correct — l'accès n'était pas le problème. `dcgm-exporter --help` a révélé `--disable-startup-validate` ("Disable validation checks during startup. Can be useful for running in minimal environments or testing") : exactement notre cas (pas de nvidia-container-runtime, passthrough manuel). Avec ce flag + `--debug`, DCGM s'initialise correctement (`DCGM successfully initialized!`) puis... `exit code 137` (OOMKilled) pendant la collecte des groupes de métriques de profiling — le `limits.memory: 256Mi` d'origine était trop juste. Monté à `1Gi`.

**Piège à noter** : un `kubectl patch --type=json` posé hors du fichier YAML (le `command` de debug) survit à un `kubectl apply -f` ultérieur si le champ n'était pas déjà suivi par l'annotation `last-applied-configuration` — a fait réapparaître un panic Go absurde (`Invalid entry, please use ./sleep <time>`) sur le déploiement "propre". Nettoyé avec un second patch JSON (`"op": "remove"`).

### Résultat

Pod stable (`1/1 Running`, 0 restart après 90s), métriques réelles exposées sur `:9400/metrics` (`DCGM_FI_DEV_GPU_UTIL`, `_FB_USED`, `_FB_FREE`, `_GPU_TEMP`, ...) pour la RTX 4060. Scrape Prometheus (`job=dcgm-exporter`) passé à `up`.

---

## Grafana

`grafana-datasource-configmap.yaml` (datasource Prometheus, `uid: prometheus` figé pour que le JSON du dashboard puisse le référencer directement), `grafana-dashboard-provider-configmap.yaml` (provider de type `file`, dossier `vLLM`), `grafana-dashboard-json-configmap.yaml` (le dashboard lui-même, monté dans `/var/lib/grafana/dashboards`), `grafana-deployment.yaml`, `grafana-service.yaml`. Provisioning 100% par fichiers, aucun état à persister (pas de PVC) — tout est reconstruit au démarrage du pod.

Dashboard **vLLM + GPU** (8 panels) : requêtes running/waiting, débit en tokens/s, TTFT p50/p95, latence inter-token p50/p95, usage KV cache, utilisation GPU, mémoire GPU (used/free), température/power du GPU.

Pas de bloqueur cette fois — a marché du premier coup. Vérifié de bout en bout via l'API Grafana (`/api/datasources/proxy/uid/prometheus/api/v1/query`) : la chaîne Grafana → Prometheus → DCGM exporter renvoie bien la température réelle du GPU (39°C).

Accès (pas d'`extraPortMappings` sur ce cluster, cf. semaine 3) :
```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000
# admin/admin — lab local uniquement, pas d'exposition externe
```

---

## Resource management GPU : requests/limits, nodeAffinity, tolerations

`nvidia.com/gpu: "1"` était déjà posé en requests/limits sur `vllm-server` depuis la semaine 3 — rien à ajouter là.

Labellisé le nœud (`kubectl label node vllm-cluster-control-plane nvidia.com/gpu.present=true`, convention NVIDIA GPU Feature Discovery) et ajouté à `kubernetes/deployment.yaml` une `nodeAffinity` `requiredDuringSchedulingIgnoredDuringExecution` dessus + une `toleration` sur un taint `nvidia.com/gpu:NoSchedule`.

Sur ce cluster mono-nœud, ces deux ajouts sont honnêtement plus symboliques que fonctionnels : il n'y a qu'un seul nœud, donc rien à isoler de rien. Délibérément **pas** posé le taint correspondant sur le nœud — un cluster à un seul nœud taint-é bloquerait aussi coredns, ingress-nginx, KEDA, Prometheus et Grafana, qui n'ont pas la toleration. Le vrai bénéfice de cette paire affinity/toleration arrivera en semaine 5-6 (migration EKS, node groups GPU dédiés via Karpenter) où le taint sera posé pour de vrai sur les nœuds `g5.xlarge` par le provisioner, et empêchera effectivement des pods non-GPU de s'y faire scheduler.

### Bloqueur (découvert en testant le nouveau `nodeAffinity`) : le même bug `/dev/cpu/*/cpuid` touche aussi vLLM

Pour vérifier que la `nodeAffinity` fonctionnait, passage de `vllm-server` en stratégie `Recreate` (même leçon que Prometheus : `RollingUpdate` sur un nœud à **un seul GPU** laisse le nouveau pod bloqué en `Pending` — `Insufficient nvidia.com/gpu` — tant que l'ancien tient l'unique unité). Une fois `Recreate` appliqué, le nouveau pod vLLM a percuté **exactement** le même bug que `dcgm-exporter` plus haut : `error creating device nodes: mount /dev/cpu/1/cpuid ... no such file or directory`, causé par `privileged: true` qui tente de mirrorer tous les devices du nœud kind, y compris ce `/dev/cpu/1/cpuid` cassé.

Ce bug dormait depuis le début de la semaine : le pod vLLM tournant depuis la semaine 3 avait été créé *avant* que ce device ne casse (probablement pendant un redémarrage du conteneur nœud à un moment de cette semaine), et n'avait donc jamais été recréé pour le révéler. Il aurait fini par apparaître au prochain redémarrage de toute façon — bon moment pour le corriger.

**Fix** : retiré `privileged: true` de `kubernetes/deployment.yaml`, remplacé par `securityContext.capabilities.add: [SYS_ADMIN]` (même traitement que `dcgm-exporter`). Les mounts explicites `/dev/nvidia*` + libs restent inchangés et suffisent — vérifié avec une requête `/v1/completions` de bout en bout après le redémarrage, réponse correcte.

---

## Benchmarking sous charge

`scripts/benchmark.py` réécrit : d'un run séquentiel unique (20 requêtes, baseline semaine 1) vers un balayage de niveaux de concurrence croissants (`--levels`, `ThreadPoolExecutor`), avec mesure du throughput agrégé et de la latence p50/p95 par palier, et arrêt automatique du balayage à la première défaillance (`--no-stop-on-failure` pour désactiver).

### Bloqueur : `/v1/chat/completions` — erreur 400 sur le chat template

Le premier run a échoué instantanément (`0/8 ok`) : `As of transformers v4.44, default chat template is no longer allowed`. Déjà repéré en semaine 3 (`docs/week-03-notes.md`, "problème applicatif distinct, pas bloquant") mais jamais résolu — devenait bloquant maintenant qu'on veut vraiment charger le serveur. Plutôt que de construire un chat template pour ce tokenizer, basculé le script sur `/v1/completions` (prompt brut, pas de rôle chat) — cohérent avec le test de streaming SSE de la semaine 3 qui utilisait déjà cet endpoint.

### Résultats (via `kubectl -n vllm port-forward svc/vllm-service 8000:8000`)

| Concurrence | Requêtes | Throughput agrégé | p50 | p95 | Échecs |
|---|---|---|---|---|---|
| 1  | 8   | 61 tok/s  | 1.6s | 1.7s | 0 |
| 4  | 8   | 231 tok/s | 1.7s | 1.7s | 0 |
| 16 | 16  | 763 tok/s | 2.1s | 2.1s | 0 |
| 32 | 64  | 772 tok/s | 6.6s | 9.5s | 0 |
| 64 | 64  | 729 tok/s | 11.1s | 15.8s | 0 |
| 128| 128 | 615 tok/s | 33.6s | 55.6s | 0 |

Le throughput agrégé plafonne autour de **~750-770 tok/s** dès la concurrence 16-32 (plafond compute de la RTX 4060 sur ce modèle/quantization) — au-delà, la concurrence supplémentaire n'augmente plus le débit, elle ne fait qu'allonger la latence par requête (file d'attente plus longue).

### "Étude des limites d'OOM sur la KV cache" — pas de crash, du throttling

Le guide de la semaine 4 demandait d'étudier les limites d'OOM sur la KV cache. Résultat contre-intuitif mais correct : **aucun crash, aucune requête en échec**, même à 128 requêtes simultanées avec `max_tokens=400`. Capturé en interrogeant Prometheus (`vllm:kv_cache_usage_perc`, `vllm:num_requests_running`, `vllm:num_requests_waiting`) pendant un burst de 128 requêtes :

```
t=1s : kv_cache=68%  running=128 waiting=0
t=3s : kv_cache=99.5% running=15  waiting=89   ← pic de saturation
t=6s : kv_cache=97%  running=18  waiting=50
t=8s : kv_cache=98%  running=34  waiting=0
```

La KV cache est montée à ~99.5% d'utilisation, mais au lieu de se faire OOM-killer, le scheduler vLLM a **réduit `num_requests_running` de 128 à 15** pour rester sous le budget mémoire, en mettant le reste en file d'attente (`num_requests_waiting` jusqu'à 89). C'est tout l'intérêt du continuous batching + PagedAttention de vLLM : la limite de mémoire se traduit en admission control (throttling), pas en crash — contrairement à un service naïf qui accepterait toutes les requêtes et OOM-crasherait. La contrepartie est la latence : p95 passe de 1.7s (concurrence 1) à 55.6s (concurrence 128).

**Conclusion pratique** : sur ce GPU (RTX 4060 8 Go, `--gpu-memory-utilization 0.6`, `--max-model-len 880`), ~16-32 requêtes concurrentes suffisent à saturer le débit compute ; au-delà, KEDA (dont le trigger Prometheus est maintenant fonctionnel, cf. plus haut) devrait scaler `vllm-server` sur `vllm:num_requests_waiting > 5` plutôt que de laisser la latence se dégrader — reste à vérifier en pratique avec plusieurs replicas GPU, ce qui suppose plusieurs GPU disponibles (hors de portée sur cette workstation à un seul GPU ; à tester en semaine 5-6 sur EKS avec plusieurs nœuds `g5.xlarge`).
