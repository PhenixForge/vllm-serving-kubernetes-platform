# Terraform — Semaine 6 (migration EKS)

IaC pour l'infrastructure AWS uniquement (VPC, EKS, Karpenter). Les manifestes Kubernetes applicatifs restent dans [`../kubernetes/`](../kubernetes/) — rien de la semaine 1 à 5 (cluster `kind` local, docs, scripts) n'est touché par ce dossier.

**Rien n'a été appliqué.** Ce code a été écrit et validé (`terraform init` + `terraform validate` + `terraform plan` jusqu'au mur attendu des credentials manquantes) mais jamais provisionné — pas de credentials AWS configurées sur cette machine au moment de l'écriture.

## Politique de versions (éviter le toil)

Cible : **Kubernetes 1.36** (dernière version en support standard EKS, vérifiée sur la [doc officielle AWS](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) le 2026-09-21) sur **AL2023**. Avant d'écrire ou de changer une version : calendrier de support EKS, notes de version de la version cible, matrice de compatibilité Karpenter, versions courantes des providers/modules dans le registre Terraform — jamais de mémoire. Un `validate` vert ne prouve pas qu'une version est encore supportée ; c'est ce genre d'écart, découvert après le déploiement, qui génère du toil (upgrade forcé, surcoût de support étendu, AMI introuvable). Détail dans [`../docs/week-06-notes.md`](../docs/week-06-notes.md).

## Avant de lancer un `apply` : re-vérifier les versions

Ce code a été écrit à une date donnée (dernière vérification : **2026-09-21**) et le projet s'étale sur plusieurs mois : entre l'écriture et un `apply` réel, EKS aura sorti une nouvelle version, une autre passera en fin de support standard, et des modules/providers auront bougé. Ne pas appliquer sur la foi de ce fichier — refaire cette vérification (quelques minutes, contre des sources officielles) :

1. **Version Kubernetes** — `aws eks describe-cluster-versions --region <region>` (statut de support et `endOfStandardSupportDate` de chaque version) ou la [page EKS](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html). Ajuster `cluster_version` (`variables.tf`) sur la plus récente en support standard.
2. **Compatibilité Karpenter** — [matrice](https://karpenter.sh/docs/upgrading/compatibility/) : version de chart minimale pour la version Kubernetes visée (`karpenter.tf`).
3. **Notes de version EKS** de la version visée — fonctionnalités retirées/dépréciées à recouper avec `kubernetes/` et `kubernetes-eks/`.
4. **Providers et modules** — versions courantes dans le registre Terraform, changelog des majeures (`versions.tf`, `eks.tf`, `vpc.tf`).
5. **AMI** — l'alias `al2023@latest` suit les nouvelles publications (Karpenter remplacera les nœuds à la dérive) ; l'épingler (`al2023@vYYYYMMDD`) ou passer à une AMI Packer pour un environnement reproductible.
6. `terraform init -upgrade && terraform validate && terraform plan`, puis relire le plan — `validate` ne détecte pas une version périmée.

Puis mettre à jour la date ci-dessus.

## Ce que ça déploie

- Un VPC dédié (3 AZ, subnets publics/privés, 1 NAT Gateway) — `vpc.tf`
- Un cluster EKS avec un unique node group managé **non-GPU** ("système" : CoreDNS, contrôleur Karpenter, ingress-nginx, Prometheus/Grafana/DCGM, KEDA — mêmes manifestes que sur `kind`) — `eks.tf`
- Karpenter, qui provisionne les nœuds GPU (`g5.xlarge`, NVIDIA A10G 24 Go) **à la demande**, avec scale-to-zero après 5 min d'inactivité — `karpenter.tf`
- L'addon VPC CNI avec `ENABLE_NETWORK_POLICY=true` : les `NetworkPolicy` de la semaine 5 (inertes sur `kind`/kindnetd) seront réellement appliquées ici, sans modification.

## Ce que ça ne déploie PAS (encore)

Les manifestes applicatifs eux-mêmes ne sont pas gérés par ce Terraform. Une fois le cluster provisionné :
1. `aws eks update-kubeconfig --name vllm-serving --region eu-west-3` (voir l'output `configure_kubectl`)
2. Suivre [`kubernetes-eks/README.md`](../kubernetes-eks/README.md) — les manifestes EKS-spécifiques (vLLM sans passthrough GPU manuel, DCGM en stratégie envvar, StorageClass gp3, device plugin standard) sont écrits, mais **non vérifiés sur un cluster réel**. Le reste (Prometheus, Grafana, KEDA, Ingress, NetworkPolicy, Service, PVC) se réutilise tel quel depuis `kubernetes/`.

## Prérequis pour appliquer pour de vrai

- Un compte AWS avec des credentials configurées (`aws configure`, ou variables d'environnement `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`) — permissions IAM larges nécessaires (EC2, EKS, IAM, VPC, autoscaling).
- Quota de service EC2 pour au moins une instance `g5.xlarge` dans la région choisie (souvent à demander explicitement pour un compte neuf — les quotas GPU par défaut sont fréquemment à 0).

## Comment lancer

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # optionnel, les défauts de variables.tf conviennent pour un lab
terraform init
terraform plan      # relire ATTENTIVEMENT avant d'appliquer — vérifier la région, le nombre de nœuds
terraform apply
```

## ⚠️ Coût réel si appliqué

Estimation grossière, région `eu-west-3` (Paris), instances à la demande :

| Ressource | Coût approx. |
|---|---|
| Control plane EKS | ~0,10 $/h fixe, tourne en continu |
| Node group système (2x `t3.medium`) | ~0,08 $/h |
| NAT Gateway | ~0,05 $/h + trafic |
| Nœud GPU `g5.xlarge` (à la demande, pendant utilisation) | ~1,2 $/h — **scale to zero après 5 min d'inactivité** (`karpenter.tf`, `disruption.consolidateAfter`), donc pas facturé en continu si le trafic est intermittent |
| EBS (nœud système + nœud GPU quand actif) | quelques centimes/h |

Le control plane EKS + node group système + NAT tournent **en continu** dès l'apply, que le GPU soit utilisé ou non — grossièrement **0,25-0,30 $/h** (~180-220 $/mois) de socle fixe, avant même de compter le GPU. `terraform destroy` arrête toute la facturation (cf. plus bas).

## Détruire

```bash
terraform destroy
```

**Destructif et volontairement laissé à l'utilisateur** — jamais exécuté par l'assistant (même consigne que pour le cluster `kind` local, cf. mémoire du projet), a fortiori ici où ça touche de vraies ressources AWS facturées.

## Backend d'état

Backend local par défaut (`terraform/terraform.tfstate`, gitignored) — adapté à un usage solo. Pour un usage en équipe ou CI, migrer vers un backend S3 + verrouillage DynamoDB (bloc `backend "s3" {}` dans `versions.tf`, à bootstrapper séparément avant le premier `init`).
