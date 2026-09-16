# Week 05 — Notes

## Reprise de session

Même procédure que les semaines précédentes (`podman start vllm-cluster-control-plane` + export kubeconfig). Même pod fantôme `vllm-server` en `UnexpectedAdmissionError` au redémarrage (device-plugin GPU qui se ré-enregistre) — nettoyé par `kubectl delete pod`. Rien de nouveau ici, cf. docs/week-03-notes.md et docs/week-04-notes.md pour le détail de ce rituel.

---

## NetworkPolicies : écrites, appliquées, **inertes**

`kubernetes/network-policy.yaml` — trois policies dans le namespace `vllm` : deny-all par défaut, puis trous explicites (ingress applicatif depuis `ingress-nginx` uniquement + ingress `/metrics` depuis `monitoring` — la consigne littérale du guide, "uniquement depuis le contrôleur Ingress", aurait cassé le scraping Prometheus construit en semaine 4 ; interprété comme un oubli du guide plutôt que suivi à la lettre), egress DNS + HTTPS sortant (443) pour un futur changement de modèle Hugging Face.

**Avant d'écrire quoi que ce soit** : vérifié que ce cluster kind tourne avec `kindnetd` comme CNI (`kubectl -n kube-system get ds kindnet -o jsonpath='{.spec.template.spec.containers[0].image}'` → `kindest/kindnetd:v20240202-...`), et qu'aucun contrôleur de policy (Calico, Cilium) n'est installé. kindnetd fait du routage de base, pas d'enforcement de NetworkPolicy.

**Test empirique** (plutôt que de se fier à la doc générale) : après application des trois policies (deny-all + trous), lancé un pod `curl` dans le namespace `default` (qui ne matche aucune règle `allow`) ciblant `vllm-service.vllm.svc.cluster.local:8000/health` → **`HTTP 200`**. La requête aurait dû être bloquée et ne l'est pas : confirmation que les NetworkPolicy sont acceptées par l'API server (donc valides et versionnées) mais **n'ont strictement aucun effet** sur ce cluster.

**Décision** : garder les manifestes tels quels (IaC correcte, prête pour un CNI qui les fait respecter) plutôt que de les retirer ou d'installer Calico sur ce cluster déjà chargé de bricolages fragiles (pids-limit, inotify, passthrough GPU manuel — cf. semaines 3-4). Documenté en tête de fichier. Sur EKS (semaine 6), l'Amazon VPC CNI supporte nativement l'enforcement des NetworkPolicy depuis la 1.25 (flag `ENABLE_NETWORK_POLICY`) — ces mêmes manifestes y seront appliqués sans modification, pour de vrai cette fois.

---

## SecurityContext durci : `runAsNonRoot`, `readOnlyRootFilesystem`, capacités minimales

Objectif du guide : moindre privilège sur `vllm-server`, qui tournait jusqu'ici en root avec `SYS_ADMIN` (semaine 4). Trois bloqueurs en cascade, chacun résolu en testant sur le cluster réel plutôt qu'en devinant :

### 1. `SYS_ADMIN` n'était en fait pas nécessaire

Retiré entièrement (`capabilities: drop: ["ALL"]`, sans rien en `add`). CUDA/NVML n'en ont besoin que si le driver doit être initialisé dynamiquement (mknod, etc.) — avec les devices `/dev/nvidia*` déjà montés explicitement (hostPath), rien de plus n'est requis. Confirmé par un déploiement qui tourne sans erreur.

### 2. `runAsUser: 1000` casse `getpass.getuser()` dans torch

Premier crash : `KeyError: getpwuid(): uid not found: 1000`, dans `torch._inductor.runtime.cache_dir_utils`, qui appelle `getpass.getuser()` pour construire son chemin de cache — l'image (construite pour tourner en root) n'a pas d'entrée `/etc/passwd` pour un UID arbitraire. Fix minimal sans toucher à l'image : `getpass.getuser()` consulte d'abord les variables d'environnement (`USER`, `LOGNAME`, ...) avant de retomber sur `pwd.getpwuid()` — poser `USER=vllm` (et `HOME=/tmp` par précaution, pour tout autre appel basé sur le home) suffit à éviter tout le problème.

### 3. `/root` est intraversable pour un utilisateur non-root

Deuxième crash, plus subtil : `PermissionError` sur `/root/.cache/huggingface/token`, alors même que le PVC était monté avec le bon `fsGroup`. Cause : `/root` lui-même (hérité de l'image de base, pas du volume monté) est en `700 root:root` — un non-root ne peut même pas *traverser* ce dossier, peu importe les permissions de ce qui est monté en dessous. `fsGroup` corrige l'ownership du contenu du volume, pas celui des dossiers parents qui viennent de l'image.

**Fix** : relocalisé le cache HF hors de `/root` — `HF_HOME` passé de `/root/.cache/huggingface` à `/cache/huggingface` (`kubernetes/configmap.yaml`), mountPath du PVC modifié en conséquence (`kubernetes/deployment.yaml`). Le PVC est le même volume physique (aucune re-download du modèle — chargement depuis le cache confirmé dans les logs, ~4s).

Reste deux warnings bénins et ignorés par vLLM lui-même (`Ignored error while writing commit hash...`, `Could not cache non-existence of file...`) : quelques fichiers de métadonnées HF pré-existants sur le PVC, encore possédés par `root` avec des permissions qui n'incluent pas l'écriture groupe. Non bloquant (vLLM continue sans ces mises à jour de cache), donc pas corrigé — un `chown -R` ponctuel du PVC réglerait ça si ça devenait gênant.

### `readOnlyRootFilesystem: true`

Ajouté deux `emptyDir` : `/tmp` (cache torch.compile, confirmé dans les logs : `Using cache directory: /tmp/.cache/vllm/torch_compile_cache/...`) et `/dev/shm` en `medium: Memory, sizeLimit: 2Gi` (IPC PyTorch entre le process API et l'engine core, architecture vLLM V1 — le tmpfs par défaut du rootfs, souvent 64Mi, ne suffirait pas).

**Résultat** : pod `1/1 Running`, 0 restart, inférence testée de bout en bout (`/v1/completions`) — fonctionne identique à avant, mais sans `privileged`, sans capacité superflue, en UID 1000, rootfs en lecture seule.

---

## Secrets : pas de `kubernetes/secret.yaml` — et c'est le bon choix

Le guide demande de sortir `HF_TOKEN` des ConfigMaps vers un Secret. Vérifié (`grep -ri HF_TOKEN` sur tout le repo) : **aucun token n'est utilisé nulle part**. `TheBloke/Mistral-7B-Instruct-v0.1-AWQ` est un modèle public, pas de gate Hugging Face. Créer un Secret vide/placeholder pour cocher la case serait un artefact mort sans utilité. Documenté ici plutôt que d'ajouter un fichier fantôme : le jour où un modèle gated entre en jeu, la marche à suivre est `kubectl create secret generic hf-token --from-literal=HF_TOKEN=... ` + `envFrom.secretRef` dans `deployment.yaml`, jamais le token en clair dans un fichier commité.

---

## Graceful shutdown

`terminationGracePeriodSeconds: 30` + `lifecycle.preStop` (`sleep 5`, pour laisser le temps à kube-proxy/Ingress de retirer le pod de la rotation avant le `SIGTERM`) ajoutés à `vllm-server`. Testé en conditions réelles : `kubectl delete pod` → **~7s** jusqu'à disparition complète (5s de preStop + le temps que vLLM ferme proprement après le SIGTERM), largement dans le budget de 30s. Le pod de remplacement (stratégie `Recreate`, cf. semaine 4) est reparti sain.

Les probes existantes (`/health`, `initialDelaySeconds: 60/120`) n'ont pas eu besoin d'être desserrées : `/health` reste rapide même sous la charge du balayage de benchmark de la semaine 4 (qui poussait la latence p95 des vraies requêtes d'inférence à 55s) — c'est un endpoint de liveness indépendant de la file de requêtes du moteur, pas un round-trip de génération.

---

## Accès Ingress : Basic Auth + rate limiting

Pas de passerelle API (Kong/Envoy) dans ce lab, donc pas de vraie clé API/JWT — utilisé `nginx.ingress.kubernetes.io/auth-type: basic` (supporté nativement par ingress-nginx), qui remplit le même rôle de restriction d'accès. `nginx.ingress.kubernetes.io/limit-rps: "5"` par IP, cohérent avec le plafond de débit compute observé au balayage de charge de la semaine 4 (concurrence 16-32).

Secret `vllm-basic-auth` (htpasswd) créé à la main via `kubectl create secret generic vllm-basic-auth --from-file=auth=<htpasswd>` — **volontairement pas commité** dans `kubernetes/` (mot de passe généré par `openssl rand -base64 18`).

**Incident à noter, par transparence** : au premier essai, j'ai affiché le mot de passe généré dans le chat puis l'ai réutilisé tel quel dans une commande `curl` suivante — l'auto-mode de Claude Code a bloqué cette deuxième commande (classificateur "Credential Materialization"). Sur le principe, il avait raison : un secret réel ne devrait pas être retapé en clair d'une commande à l'autre. Le mot de passe affiché a été traité comme compromis et immédiatement invalidé — Secret régénéré avec un nouveau mot de passe, cette fois jamais affiché ni réutilisé hors d'un seul script auto-contenu. Testé (401 sans auth, 401 avec mauvais mot de passe, 200 avec le bon) sans jamais faire apparaître le mot de passe réel dans la sortie.

---

## Taints/Tolerations/NodeAffinity GPU : déjà traité en semaine 4

Le guide de la semaine 5 redemande ce que la semaine 4 avait déjà posé (`nodeAffinity` sur `nvidia.com/gpu.present=true` + `toleration` sur `nvidia.com/gpu:NoSchedule`) — et déjà expliqué pourquoi le taint lui-même reste non appliqué sur ce cluster mono-nœud (bloquerait coredns/ingress-nginx/KEDA/Prometheus/Grafana, aucun n'ayant la toleration). Rien à refaire ici, cf. `docs/week-04-notes.md` section "Resource management GPU". Le taint réel arrivera avec les node groups GPU dédiés d'EKS (semaine 6).

