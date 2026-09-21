# Semaine 7 : Autoscaling des pods vLLM sur EKS, load testing & cold start

L'objectif de cette septième étape est de **prouver sur EKS ce qui est déjà validé sur `kind`** : KEDA scale les pods vLLM sur la file d'attente, Karpenter fournit les nœuds GPU manquants, et on mesure ce que ça coûte en temps (cold start) et en argent.

> **Statut au 2026-09-21 : préparée, non exécutée.** Tout ce qui pouvait se faire sans cluster est écrit (manifestes, scripts, protocole). L'exécution dépend du `terraform apply` de la semaine 6 (credentials AWS + accord sur le coût, cf. [`terraform/README.md`](../terraform/README.md)). Rien de ce qui suit n'a encore tourné sur un vrai cluster EKS.

---

## Ce qui est déjà acquis (on ne le refait pas)

| Acquis | Où | Réutilisé ici |
|---|---|---|
| Trigger KEDA sur `vllm:num_requests_waiting` validé (`HPAActive=True`) | Semaine 4, [`week-04-notes.md`](week-04-notes.md) | Même query, mêmes seuils — adaptés dans [`kubernetes-eks/keda-scaledobject.yaml`](../kubernetes-eks/keda-scaledobject.yaml) |
| Comportement sous charge : le scheduler vLLM throttle l'admission au lieu de crasher (128 → 15 requêtes actives, KV cache à 99,5 %) | Semaine 4 | Sert de référence de comparaison, pas à re-démontrer |
| Script de balayage de charge | Semaine 4, [`scripts/benchmark.py`](../scripts/benchmark.py) | Conservé tel quel ; ajout d'un mode soutenu `--duration` |
| NetworkPolicies, SecurityContext non-root, graceful shutdown | Semaine 5 | Inchangés ; la NetworkPolicy est enfin *appliquée* (VPC CNI) |

---

## Blocages trouvés en préparant (et corrigés dans les manifestes EKS)

Relire les manifestes de `kind` en pensant « plusieurs replicas, un GPU par nœud, nœuds éphémères » fait apparaître des problèmes invisibles à 1 replica. Tous corrigés dans `kubernetes-eks/` (catalogue complet des erreurs silencieuses du projet : [`retour-d-experience.md`](retour-d-experience.md)) — `kubernetes/` (kind) n'a pas été touché.

1. **Le PVC de cache modèle empêche le 2e replica.** Un volume EBS est `ReadWriteOnce` *et* lié à une zone : un 2e pod sur un 2e nœud GPU reste bloqué (Multi-Attach / mauvaise AZ). → Cache en `emptyDir` : chaque pod télécharge les poids à froid. C'est voulu : c'est la **ligne de base du cold start**, contre laquelle comparer ensuite EFS (RWX) ou des poids embarqués dans l'AMI (Packer, cf. [`extensions/vault-and-packer.md`](extensions/vault-and-packer.md)).
2. **Les probes tueraient un pod à froid.** Sur `kind` le modèle était en cache (~4 s). Sur un nœud neuf : pull d'image + téléchargement + chargement VRAM, bien au-delà de `liveness` (120 s + 3×20 s). → `startupProbe` (jusqu'à 15 min), `initialDelaySeconds` retirés.
3. **Prometheus n'aurait vu qu'un pod sur deux.** Cible = Service ClusterIP → chaque scrape tombe sur un pod au hasard ; `sum(vllm:num_requests_waiting)` serait faux et oscillant, donc le signal KEDA aussi. → Services headless + `dns_sd_configs` ([`headless-services.yaml`](../kubernetes-eks/headless-services.yaml), [`prometheus-configmap.yaml`](../kubernetes-eks/prometheus-configmap.yaml)).
4. **DCGM en `Deployment` à 1 replica** ne supervise qu'un nœud GPU sur deux. → `DaemonSet` ([`dcgm-exporter-daemonset.yaml`](../kubernetes-eks/dcgm-exporter-daemonset.yaml), renommé).
5. **`maxReplicaCount: 4` incohérent avec Karpenter.** Le NodePool plafonne à `cpu: "8"` = 2 nœuds `g5.xlarge` ; les replicas 3 et 4 resteraient `Pending`. → `maxReplicaCount: 2`. Et les tests via l'Ingress mesureraient le rate limiting (5 req/s/IP, semaine 5) : le générateur de charge tourne **dans** le cluster ([`loadtest.yaml`](../kubernetes-eks/loadtest.yaml)), avec une NetworkPolicy additive, car le deny-all de `vllm` est désormais réellement enforcé.

---

## Prérequis avant de commencer

- [ ] Semaine 6 appliquée : cluster EKS `1.36` up, image vLLM dans ECR, `kubernetes-eks/README.md` déroulé jusqu'au bout (avec les fichiers listés ci-dessous, pas ceux de `kind`).
- [ ] **Re-vérification des versions** (checklist de [`terraform/README.md`](../terraform/README.md)) si l'`apply` a lieu longtemps après le 2026-09-21.
- [ ] **Quota AWS** « Running On-Demand G and VT instances » ≥ **8 vCPU** dans la région (4 par `g5.xlarge`, 2 nœuds). Les quotas GPU par défaut sont souvent à 0 : la demande prend du temps, à faire en avance.
- [ ] **Budget** : alarme AWS Budgets posée ; durée maximale du test décidée (voir garde-fous).
- [ ] Un seul replica vLLM `Ready` et une inférence de bout en bout réussie **avant** de lancer la charge.

## Fichiers à appliquer (remplacent les variantes `kind`)

| À la place de… | Utiliser |
|---|---|
| `kubernetes/pvc.yaml` (vLLM) | rien — cache en `emptyDir` dans [`kubernetes-eks/deployment.yaml`](../kubernetes-eks/deployment.yaml) |
| `kubernetes/prometheus-configmap.yaml` | [`kubernetes-eks/prometheus-configmap.yaml`](../kubernetes-eks/prometheus-configmap.yaml) + [`headless-services.yaml`](../kubernetes-eks/headless-services.yaml) |
| `kubernetes/dcgm-exporter-deployment.yaml` | [`kubernetes-eks/dcgm-exporter-daemonset.yaml`](../kubernetes-eks/dcgm-exporter-daemonset.yaml) |
| `kubernetes/keda-scaledobject.yaml` | [`kubernetes-eks/keda-scaledobject.yaml`](../kubernetes-eks/keda-scaledobject.yaml) |
| — (nouveau) | [`kubernetes-eks/loadtest.yaml`](../kubernetes-eks/loadtest.yaml), [`scripts/scale-timeline.sh`](../scripts/scale-timeline.sh) |

---

## Protocole d'essai

Deux terminaux : un pour la chronologie (lecture seule), un pour la charge.

**0. Vérifier l'état de départ**
```bash
kubectl -n vllm get pods,hpa,scaledobject
kubectl -n monitoring port-forward svc/prometheus-k8s 9090:9090 &
# Prometheus > Status > Targets : 1 cible vllm (UP), 1 cible dcgm-exporter (UP)
```

**1. Ligne de base à 1 replica** (10 min de charge soutenue, sous le seuil de scaling si possible — ou KEDA désactivé via `kubectl -n vllm annotate scaledobject vllm-autoscaler autoscaling.keda.sh/paused-replicas="1"`) : relever p50/p95/tok/s stables.

**2. Chronologie du scale-out**
```bash
scripts/scale-timeline.sh 5 | tee timeline-$(date -u +%Y%m%dT%H%M%SZ).csv     # terminal A
```
**3. Charge soutenue depuis le cluster**
```bash
kubectl create namespace loadtest
kubectl -n loadtest create configmap benchmark-script --from-file=benchmark.py=scripts/benchmark.py
kubectl apply -f kubernetes-eks/loadtest.yaml                                  # terminal B
kubectl -n loadtest logs -f job/vllm-loadtest                                  # une ligne / 15 s
```
Le Job est à 900 s / concurrence 32 (à ajuster dans `args` selon la baseline du A10G, différente de la RTX 4060).

**4. Après le test** : laisser la charge tomber, observer le scale-down (pods puis nœud, ~5 min + consolidation Karpenter), puis supprimer la NetworkPolicy additive et le namespace de test :
```bash
kubectl delete -f kubernetes-eks/loadtest.yaml && kubectl delete namespace loadtest
```

## Mesures à documenter (dans `docs/week-07-notes.md`, à créer depuis `week-NN-notes.md`)

| # | Événement | Source |
|---|---|---|
| T0 | Début de la charge | log du Job |
| T1 | Requêtes en file > seuil (5/replica) | Prometheus / Grafana |
| T2 | HPA `desired` = 2 | `scale-timeline.sh` |
| T3 | NodeClaim Karpenter créé | idem |
| T4 | Nœud GPU `Ready` | idem |
| T5 | Pod planifié → image tirée | `kubectl describe pod` (events) |
| T6 | Poids téléchargés + modèle chargé | logs vLLM |
| T7 | Pod `Ready` (1er `/health` OK) | `scale-timeline.sh` |

**Cold start = T2 → T7**, décomposé en : provisionnement du nœud (T2→T4), pull d'image (T4→T5+), téléchargement + chargement du modèle (→T7). Comparer la latence p95 et le throughput par fenêtre **avant T7** (1 replica saturé) et **après T7** (2 replicas). C'est aussi le chiffre « avant » de l'extension Packer.

## Garde-fous coûts

- 2 × `g5.xlarge` ≈ 2,4 $/h, en plus du socle fixe (~0,25-0,30 $/h). Un essai de 30 min reste de l'ordre de quelques dollars — **à condition de ne rien laisser tourner**.
- Durée du Job bornée (`--duration`) ; `terraform destroy` en fin de session sauf décision explicite de garder le cluster.
- Ne pas monter `maxReplicaCount` / limite NodePool / quota sans décision budgétaire.
- Scale-to-zero (`minReplicaCount: 0`) : expérience **séparée** (économie vs cold start côté utilisateur) — pas dans le premier passage.

---

## Livrables de la semaine 7

1. `docs/week-07-notes.md` : tableau chronologique T0→T7 rempli avec de vraies valeurs, courbes p95/throughput avant/après, et les écarts avec les hypothèses de ce guide.
2. Capture Grafana (file d'attente, replicas, util GPU par nœud) pendant le scale-out.
3. Critère de succès : **HPA passe à 2, Karpenter provisionne un 2e nœud GPU, le 2e pod devient `Ready`, la latence p95 baisse** — et le cold start est chiffré. Si une de ces étapes échoue, le documenter comme les blocages des semaines 3 à 5.

## Points ouverts (non traités ici)

- **Contrôleur d'ingress** : `ingress-nginx` est archivé (mars 2026). Décision en attente ; ce test ne l'utilise volontairement pas. À valider séparément (auth, 429).
- **Tag DCGM** : `nvcr.io/nvidia/k8s/dcgm-exporter:latest` non épinglé (tag exact à vérifier sur NGC) ; `<ECR_REPO_URI>:latest` idem.
- **Arguments vLLM du GPU AWS** : traités dans [`vllm-gpu-aws.md`](vllm-gpu-aws.md) (`args` du Deployment EKS, sans rebuild d'image). Les chiffres de throughput ne sont donc pas directement comparables à ceux de `kind` (contexte 8192 au lieu de 880, 90 % de VRAM au lieu de 60 %) — c'est voulu, à écrire tel quel dans les résultats.
- **Optimisations du cold start** (EFS, poids dans l'AMI) : à comparer *après* la ligne de base, dans l'extension Packer.
