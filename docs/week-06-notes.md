# Week 06 — Notes

Pas de `week6 guide.md` pré-existant (contrairement aux semaines 1-5) — scope tiré de la ligne roadmap du README : "migration to EKS with GPU nodes (g5.xlarge), Karpenter node autoscaling".

## Décision de scope : Terraform écrit, rien appliqué

Aucune credential AWS configurée sur cette machine (pas de `~/.aws`, pas de variables d'environnement, AWS CLI même pas installé) — donc rien n'aurait pu être provisionné de toute façon. Au-delà de ça, migrer vers EKS engage des coûts réels (control plane + nœuds GPU `g5.xlarge` à ~1,2 $/h) : décision explicite avec l'utilisateur de n'écrire que le Terraform cette session, sans `apply`. Consigne également reçue de ne rien écraser du travail des semaines passées (cluster `kind` local, manifestes `kubernetes/`, docs) — tout le nouveau code vit dans `terraform/`, en parallèle.

## Structure

`terraform/` — VPC dédié (`vpc.tf`), cluster EKS avec un seul node group managé **non-GPU** pour héberger CoreDNS/le contrôleur Karpenter/les workloads système (`eks.tf`), Karpenter pour provisionner les nœuds GPU à la demande (`karpenter.tf`). Détails et estimation de coût dans [`terraform/README.md`](../terraform/README.md).

Points notables :
- **VPC CNI avec `ENABLE_NETWORK_POLICY=true`** : les `NetworkPolicy` de la semaine 5, écrites et vérifiées inertes sur `kind` (kindnetd n'a pas de contrôleur de policy), seront réellement appliquées ici sans aucune modification — la promesse faite dans `kubernetes/network-policy.yaml` se concrétise.
- **Le taint `nvidia.com/gpu:NoSchedule` posé pour de vrai** sur le `NodePool` Karpenter — la toleration ajoutée sur `vllm-server` dès la semaine 4, en anticipation, explicitement documentée comme "symbolique sur un cluster mono-nœud", trouve enfin son utilité : le node group système héberge les composants non-GPU séparément, donc plus de conflit comme sur `kind`.
- **`amiFamily: AL2`** sur l'`EC2NodeClass` : Karpenter sélectionne automatiquement l'AMI EKS "accelerated" (drivers NVIDIA + `nvidia-container-runtime` préinstallés) pour les instances avec GPU — tout le passthrough manuel de `kind` (mounts `hostPath` sur `/dev/nvidia*`, libs userspace copiées à la main, cf. `docs/week-03-notes.md`) n'a plus de raison d'être ici. Pas encore vérifié en pratique (pas de cluster réel) — à confirmer au premier `apply`.
- **Pod Identity pour Karpenter, IRSA pour l'EBS CSI driver** — pas un choix cohérent délibéré, une contrainte : cf. section suivante.
- **`kubectl_manifest` (provider `gavinbunney/kubectl`) plutôt que `kubernetes_manifest`** pour les CRD Karpenter (`NodePool`/`EC2NodeClass`) : `kubernetes_manifest` exige que le CRD existe déjà au moment du `plan`, ce qui casse quand le CRD est créé dans le même `apply` (par le chart Helm juste avant) — piège classique documenté dans les exemples officiels `terraform-aws-modules/eks`.

## Vérification sans AWS : jusqu'où on peut pousser sans credentials

`terraform init` (télécharge providers + modules, pas besoin de credentials AWS) → succès. `terraform validate` → succès. Poussé plus loin : `terraform plan` échoue exactement où attendu (`No valid credential sources found`), confirmant que toute la configuration — graphe de dépendances, types, noms d'attributs des modules — est correcte jusqu'au mur des credentials. Vérifié aussi à la main les noms de champs des modules tierces dans les blocs `type = any` (non couverts par `validate`) directement dans leur code source téléchargé (`.terraform/modules/`) plutôt que de faire confiance à la mémoire.

## Dérive de version : la connaissance de l'assistant s'arrête à janvier 2026

Question posée après le premier jet : pourquoi `hashicorp/helm` résolvait en `2.17.0` alors qu'on est "en 3.20.0 et plus" ? Confusion légitime à clarifier d'abord : le numéro de version du **provider Terraform** `hashicorp/helm` n'a jamais suivi celui du **binaire Helm** lui-même (2.x du provider ciblait déjà Helm 3 en interne — deux projets, deux versionnages indépendants). Mais la question a débusqué un vrai problème derrière : la contrainte `~> 2.14` que j'avais posée pour ce provider était sincèrement datée — ma connaissance s'arrête à janvier 2026, et on est maintenant au 17 septembre 2026. Vérifié contre le registre Terraform (pas contre ma mémoire) : **tout** avait eu une bump majeure depuis l'écriture initiale de ce Terraform :

| Dépendance | Épinglé initialement | Réellement disponible |
|---|---|---|
| `hashicorp/helm` (provider) | `~> 2.14` (→2.17.0) | `~> 3.3` (3.3.0) |
| `hashicorp/kubernetes` (provider) | `~> 2.31` | `~> 3.2` (3.2.1) |
| `hashicorp/aws` (provider) | `~> 5.60` | `~> 6.65` (6.65.0) |
| `terraform-aws-modules/eks/aws` | `~> 20.31` | `~> 21.25` (21.25.0) |
| `terraform-aws-modules/vpc/aws` | `~> 5.13` | `~> 6.7` (6.7.2) |
| `terraform-aws-modules/iam/aws` | `~> 5.44` | `~> 6.8` (6.8.1) |
| Chart Helm Karpenter | `1.0.6` | `1.14.1` |

Toutes des montées de version **majeure** — donc changements cassants attendus, pas de simples bumps de patch. Plutôt que de laisser du code sciemment daté, tout mis à jour et re-vérifié à la main contre le code source réellement téléchargé (`.terraform/modules/`, `terraform providers schema -json`) plutôt que contre la mémoire, cassures trouvées et corrigées :

- **`terraform-aws-modules/eks/aws` v21** a renommé la plupart des variables `cluster_*` en retirant le préfixe (`cluster_name`→`name`, `cluster_version`→`kubernetes_version`, `cluster_endpoint_public_access`→`endpoint_public_access`, `cluster_addons`→`addons`) — mais gardé le préfixe sur les **outputs** (`cluster_name`, `cluster_endpoint`, ... inchangés). Piège à sens unique facile à louper.
- **Le sous-module `karpenter`** de ce même module a **retiré le support IRSA** en v21 (`enable_irsa`/`irsa_oidc_provider_arn` n'existent plus) — Pod Identity devient le seul mécanisme proposé. Contrainte plus un choix : Karpenter passe en Pod Identity (nécessite l'addon `eks-pod-identity-agent`, ajouté dans `eks.tf`), tandis que l'EBS CSI driver (module IAM séparé, toujours en IRSA côté lui) reste inchangé — d'où la coexistence des deux mécanismes, pas un choix cohérent délibéré comme écrit dans le premier jet.
- **`terraform-aws-modules/iam/aws` v6** a renommé le sous-module lui-même (`iam-role-for-service-accounts-eks` → `iam-role-for-service-accounts`, suffixe retiré) et ses champs (`role_name`→`name`, output `iam_role_arn`→`arn`).
- **`hashicorp/helm` provider v3** (migration vers le terraform-plugin-framework) a transformé le bloc imbriqué `kubernetes { ... }` du provider en attribut objet `kubernetes = { ... }` (syntaxe `=`) — cassant sans warning de dépréciation préalable.

Re-vérifié à la fin : `terraform init` + `validate` + `plan` (jusqu'au mur credentials attendu) tous verts sur les nouvelles versions.

**Leçon générale** : ne pas faire confiance aux numéros de version qu'un LLM pose de mémoire dans un `versions.tf`, même quand le code semble cohérent et passe `validate` au moment de l'écriture — la connaissance de l'assistant a une date de péremption, et ce projet avance plus vite que sa dernière mise à jour d'entraînement. Vérifier contre le registre est peu coûteux (`curl` + un peu de JSON) comparé au risque de coder contre une API qui n'existe plus.

## Manifestes Kubernetes EKS-spécifiques

`kubernetes-eks/` — uniquement ce qui diffère réellement de `kind` : `deployment.yaml` (vLLM sans passthrough GPU manuel, image ECR), `dcgm-exporter-deployment.yaml` (stratégie envvar `NVIDIA_VISIBLE_DEVICES=all` plutôt que mounts manuels), `configmap.yaml` (retire le contournement mémoire CUDA graph spécifique à la RTX 4060 8 Go partagée — le A10G du `g5.xlarge` a 24 Go dédiés), `nvidia-device-plugin.yaml` (version upstream standard, non patchée), `storageclass.yaml` (gp3 par défaut — EKS n'en a pas nativement, contrairement à `kind`/local-path-provisioner). Tout le reste (Grafana, KEDA, Ingress, `NetworkPolicy`, Service, PVC) se réutilise tel quel depuis `kubernetes/`. Détails et ordre de déploiement dans [`kubernetes-eks/README.md`](../kubernetes-eks/README.md).

Point de correction pendant l'écriture : premier jet du DCGM exporter EKS avait `resources.limits."nvidia.com/gpu": 1` — repéré avant de committer que la version `kind` ne le fait jamais (`grep -c "nvidia.com/gpu"` → 0), et pour cause : sur un nœud `g5.xlarge` à un seul GPU, ça aurait mis DCGM en concurrence directe avec vLLM pour l'unique unité annoncée par le device plugin, laissant l'un des deux en `Pending`. Corrigé vers la stratégie envvar, qui n'a pas besoin de réclamer la ressource comptée par Kubernetes.

**Rien de tout ça n'est vérifié sur un cluster réel** — écrit par raisonnement à partir de ce qui a été appris sur `kind`, pas observé. Signalé explicitement en tête de chaque fichier.

## Reste à faire

- `terraform apply` réel — nécessite credentials AWS + accord explicite sur le coût (à faire par l'utilisateur, jamais par l'assistant, même logique que pour la suppression du cluster `kind`).
- Vérifier en pratique que `amiFamily: AL2` sélectionne bien l'AMI accélérée attendue pour `g5.xlarge`, et que la stratégie envvar de DCGM fonctionne comme prévu.
- KEDA et ingress-nginx encore installés en `kubectl apply` d'un bundle upstream plutôt qu'en Terraform (cohérent avec la méthode `kind`, mais pas unifié avec Karpenter qui lui est en `helm_release`).
- `--max-model-len`/`--gpu-memory-utilization`, figés dans l'image pour la RTX 4060, pas reconsidérés pour les 24 Go du A10G (changement d'image, pas de manifeste).
