# Retour d'expérience — les erreurs qui ne font pas de bruit

> Constitué le 2026-09-21 à partir des notes des semaines 3 à 7 et de l'historique git. Ce document ne décrit pas des bugs spectaculaires : il recense ceux **qui ne produisent aucune erreur** — la config est valide, le pod tourne, l'API répond — et qui n'apparaissent qu'en testant autrement, à une autre échelle, dans un autre environnement, ou à une date ultérieure. C'est le type de défaut le plus coûteux en production, et celui que ce projet a le plus rencontré.

## Le motif récurrent

Un `terraform validate` vert, un pod `Running`, un `kubectl apply` sans erreur ne prouvent qu'une chose : **le système accepte l'entrée**. Ils ne disent ni que la règle est appliquée, ni que le résultat est celui attendu, ni que ça tiendra à deux replicas ou dans trois mois.

## Catalogue

### A. Vert à l'écran, faux en réalité

| Surprise | Ce qu'on voyait | Ce qui se passait | Comment on l'a trouvé | Semaine |
|---|---|---|---|---|
| **NetworkPolicy inerte** | Les 3 policies acceptées par l'API server, aucune erreur | `kindnetd` n'a pas de moteur de policy : un pod hors liste blanche atteignait quand même le service (HTTP 200) | Test empirique délibéré, pas la doc générale | 5 |
| **Kubernetes 1.30 + `AL2` sur EKS** | `init`, `validate`, `plan` verts (jusqu'au mur des credentials) | 1.30 hors support standard ; EKS ne publie plus d'AMI AL2 au-delà de la 1.32 ; `amiSelectorTerms` obligatoire en API v1 : l'`apply` aurait échoué ou facturé du support étendu | Relecture contre la doc officielle AWS et la doc Karpenter, à la demande de l'utilisateur | 6 |
| **Versions figées de mémoire** | Code cohérent, `validate` vert | Toutes les dépendances avaient pris une version majeure (`aws` 5→6, `helm` 2→3, modules EKS/VPC/IAM, chart Karpenter 1.0.6→1.14.1) | Une question sur un numéro de version, puis vérification contre le registre | 6 |
| **Renommages asymétriques** | — | Module EKS v21 : variables sans préfixe `cluster_`, *outputs* qui le gardent ; Karpenter v21 : IRSA retiré au profit de Pod Identity | Lecture du code source des modules téléchargés (`.terraform/modules/`), pas de la mémoire | 6 |
| **`kind load docker-image`** | `podman images` montre bien l'image | La commande échoue avec le provider podman (« image not present locally ») : message trompeur | Contournement documenté : `podman save` puis `kind load image-archive` | 3 |

### B. Ça tourne, mais ça mesure ou supervise la mauvaise chose

| Surprise | Ce qui se passait | Détection | Semaine |
|---|---|---|---|
| **Prometheus derrière un Service ClusterIP** | À 2 replicas, chaque scrape tombe sur un pod au hasard : `sum(vllm:num_requests_waiting)` faux et oscillant, donc signal KEDA faux | Relecture des manifestes en pensant « N replicas » — pas d'erreur à 1 replica | 7 |
| **DCGM en `Deployment` à 1 replica** | Avec 2 nœuds GPU, un seul est supervisé | Idem | 7 |
| **Test de charge via l'Ingress** | Le rate limiting (5 req/s/IP, semaine 5) serait mesuré à la place de vLLM | Raisonnement sur ce que chaque maillon impose | 7 |
| **Arguments vLLM de la RTX 4060 sur un A10G** | `--max-model-len 880` et 60 % de VRAM sur 24 Go : le serveur répond, passe à côté de la capacité | Relecture du `CMD` de l'image en changeant de GPU ([`vllm-gpu-aws.md`](vllm-gpu-aws.md)) | 7 |
| **Seuil KEDA calibré sur la 4060** | Avec ~100 000 tokens de cache KV au lieu de quelques milliers, la file d'attente apparaît bien plus tard : le scale-out peut ne jamais se déclencher au niveau de charge prévu | Raisonnement sur la capacité, à confirmer par la baseline réelle | 7 |
| **Benchmark limité par le compute, pas par la mémoire** | On cherchait la limite OOM du cache KV ; vLLM ne crashe pas : il réduit l'admission (128 → 15 requêtes actives, cache à 99,5 %) | Balayage de concurrence jusqu'à 128 | 4 |

### C. Ce qui n'échoue qu'à froid ou à l'échelle

| Surprise | Pourquoi invisible avant | Correction | Semaine |
|---|---|---|---|
| **PVC EBS et 2e replica** | Volume `ReadWriteOnce` lié à une zone : un 2e pod sur un 2e nœud GPU reste bloqué. Invisible à 1 replica | Cache en `emptyDir` (cold start = ligne de base mesurée) | 7 |
| **Liveness qui tue le pod au démarrage** | Sur `kind`, modèle en cache : chargement en ~4 s. Sur un nœud neuf : pull d'image + téléchargement + VRAM | `startupProbe` (15 min) | 7 |
| **`maxReplicaCount: 4` vs NodePool** | Le NodePool plafonne à 2 nœuds : les replicas 3 et 4 resteraient `Pending` sans erreur | `maxReplicaCount: 2`, quota AWS vérifié en amont | 7 |
| **Quota GPU AWS** | Les quotas « G and VT » par défaut sont souvent à 0 : le `plan` passe, les nœuds ne démarrent jamais | Prérequis explicite, demande à faire tôt | 6-7 |

### D. Hypothèses héritées d'un autre environnement

| Surprise | Origine | Semaine |
|---|---|---|
| **`runAsUser: 1000` casse `torch`** (`getpass.getuser()` : `KeyError`) | L'image suppose root ; UID sans entrée `/etc/passwd`. Corrigé par `USER`/`HOME` | 5 |
| **`/root` en `700`** | Un non-root ne peut pas *traverser* `/root`, quel que soit le volume monté dessous ; `fsGroup` ne corrige pas les dossiers hérités de l'image. Cache HF déplacé vers `/cache` | 5 |
| **`privileged` puis `SYS_ADMIN` inutiles** | Posés pour le passthrough GPU manuel de `kind` ; `privileged` retiré en semaine 4 (remplacé par `SYS_ADMIN`), puis `SYS_ADMIN` lui-même retiré en semaine 5 après vérification qu'il n'était pas nécessaire | 4-5 |
| **`chat template` absent** | Depuis `transformers` v4.44 : `/v1/chat/completions` refusé, d'où `/v1/completions` + `--trust-request-chat-template` | 3-4 |
| **Pod « fantôme » au redémarrage** | `UnexpectedAdmissionError` : le device plugin GPU se ré-enregistre après un redémarrage du cluster ; pod supprimé à la main | 3-5 |

### E. Limites du lab local qui contaminent le diagnostic

`pids-limit` du conteneur kind (2048) : `nginx` en `pthread_create failed` ; `inotify` : `keda-operator` en `CrashLoopBackOff` (« too many open files ») ; `APIService v1beta1.external.metrics.k8s.io` disparu (KEDA sans métriques, réappliqué depuis le bundle) ; device `/dev/cpu/*/cpuid` cassé dans le nœud kind, qui faisait échouer DCGM et masquait que `privileged` était superflu. Point commun : chaque symptôme ressemblait à un bug applicatif, la cause était l'environnement (cf. [`week-03-notes.md`](week-03-notes.md), [`week-04-notes.md`](week-04-notes.md)).

### F. Ce qui vieillit sans prévenir

| Constat au 2026-09-21 | Détail |
|---|---|
| **`ingress-nginx` archivé** (dernier push 2026-03-23) | Toute la protection d'accès de la semaine 5 repose sur ses annotations ; décision de remplacement en attente |
| **Images non à jour ou non épinglées** | Prometheus v2.55.1 (la 3.14.0 existe), Grafana 11.3.1 (13.2.2), DCGM `:latest`, `<ECR_REPO_URI>:latest` |
| **Cluster `kind` en 1.30** | Volontairement non touché, mais très en retrait de la cible EKS 1.36 |
| **Connaissance de l'assistant** | Arrêtée en janvier 2026, alors que le projet se déroule en septembre : tout numéro de version posé de mémoire est suspect (voir [README](../README.md#version-policy--provisioning-without-toil)) |

### G. Erreurs de documentation et de process

| Surprise | Détail |
|---|---|
| **Statuts désynchronisés** | README et `summary.md` affichaient des états différents pendant des semaines |
| **Badges faux ou non fondés** | Badge Go 1.22+ sans aucun code Go ; badge Kubernetes 1.26+ ; badge licence Apache 2.0 alors qu'aucun fichier `LICENSE` n'existait (ajouté depuis) |
| **Message de commit trompeur** | `6405b71` « week5: Terraform code » contient le Terraform de la semaine 6 ; l'historique n'est volontairement pas réécrit |
| **Affirmation fausse dans mes propres notes** | « Le réglage vLLM du A10G demande un changement d'image » : faux, l'ENTRYPOINT est `vllm serve` et les `args` du pod suffisent — corrigé le jour même en relisant la source |
| **Chronologie approximative** | Une première version du README parlait d'une « pause juin → août » ; l'historique git montre du travail jusqu'au 3 juillet et un vrai trou du 3 juillet au 18 août |
| **Secret affiché en clair** | Mot de passe Basic Auth affiché puis réutilisé dans la même session : traité comme compromis, régénéré, jamais réaffiché (cf. semaine 5) |
| **Guide qui redemande du déjà fait** | Le guide de la semaine 5 demandait taints/tolerations déjà posés en semaine 4 ; et sa consigne « ingress uniquement » aurait coupé le scraping Prometheus |

## Ce qui a permis de les trouver

1. **Tester le comportement, pas l'acceptation** : un pod hors liste blanche pour la NetworkPolicy ; une inférence de bout en bout après chaque durcissement.
2. **Lire la source, pas la mémoire** : code des modules Terraform téléchargés, Dockerfile et `arg_utils.py` de vLLM v0.20.2, matrice de compatibilité Karpenter.
3. **Comparer à la documentation officielle datée** du fournisseur pour l'environnement ciblé.
4. **Relire pour N replicas et des nœuds éphémères**, pas pour le cas à un pod qui marche.
5. **Comparer à ce qui marche déjà** plutôt que valider ce qui « semble idiomatique » (le DCGM avec `nvidia.com/gpu` en ressource).
6. **Se demander ce qu'un résultat mesure vraiment** avant de le comparer à un autre.
7. **Dater chaque affirmation** et prévoir une re-vérification avant l'action irréversible (`apply`).

## Ce que ça change dans la façon de travailler

- Un critère de succès doit être **observable** (« le 2e pod est `Ready` et p95 baisse »), pas « la commande n'a pas échoué ».
- Toute affirmation sur une version, un support ou un comportement porte sa **date** et sa **source**.
- Tout manifeste écrit sans cluster réel est signalé comme **non vérifié** en tête de fichier — c'est déjà le cas dans `kubernetes-eks/`.
- Une hypothèse fausse trouvée est **consignée avec sa correction**, y compris quand elle vient de l'assistant : c'est de l'information, pas de l'embarras.
