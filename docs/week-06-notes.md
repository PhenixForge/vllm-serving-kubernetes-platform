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
- **IRSA plutôt que Pod Identity** pour Karpenter (le sous-module officiel supporte les deux) : cohérent avec le rôle IRSA déjà posé pour l'EBS CSI driver — un seul mécanisme d'auth plutôt que deux mélangés.
- **`kubectl_manifest` (provider `gavinbunney/kubectl`) plutôt que `kubernetes_manifest`** pour les CRD Karpenter (`NodePool`/`EC2NodeClass`) : `kubernetes_manifest` exige que le CRD existe déjà au moment du `plan`, ce qui casse quand le CRD est créé dans le même `apply` (par le chart Helm juste avant) — piège classique documenté dans les exemples officiels `terraform-aws-modules/eks`.

## Vérification sans AWS : jusqu'où on peut pousser sans credentials

`terraform init` (télécharge providers + modules, pas besoin de credentials AWS) → succès. `terraform validate` → succès. Poussé plus loin : `terraform plan` échoue exactement où attendu (`No valid credential sources found`), confirmant que toute la configuration — graphe de dépendances, types, noms d'attributs des modules — est correcte jusqu'au mur des credentials. Vérifié aussi à la main les noms de champs des modules tierces dans les blocs `type = any` (non couverts par `validate`) directement dans leur code source téléchargé (`.terraform/modules/`) plutôt que de faire confiance à la mémoire : `cluster_addons.configuration_values`/`service_account_role_arn`, `eks_managed_node_groups.instance_types`/`min_size`/`max_size`/`desired_size`/`labels`, tous les outputs du sous-module `karpenter` (`iam_role_arn`, `queue_name`, `node_iam_role_name`).

## Reste à faire

- Manifestes Kubernetes EKS-spécifiques (`kubernetes-eks/` ou overlay Kustomize) : vLLM sans le passthrough GPU manuel, DCGM idem — pas commencé, prochaine session.
- `terraform apply` réel — nécessite credentials AWS + accord explicite sur le coût (à faire par l'utilisateur, jamais par l'assistant, même logique que pour la suppression du cluster `kind`).
- Vérifier en pratique que `amiFamily: AL2` sélectionne bien l'AMI accélérée attendue pour `g5.xlarge`.
