# IAM (rôle contrôleur + rôle/instance-profile des nœuds + file SQS pour les
# notifications d'interruption spot/rebalance) via le sous-module officiel —
# évite de réécrire à la main les ~8 ressources IAM que Karpenter attend.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.25"

  cluster_name = module.eks.cluster_name

  # Le nœud "système" (eks.tf) a déjà un rôle IAM créé par le node group
  # managé ; Karpenter a besoin d'un profil d'instance équivalent pour les
  # nœuds QU'IL lance lui-même.
  #
  # Pod Identity, pas IRSA : v21 de ce sous-module a retiré le support IRSA
  # (enable_irsa/irsa_oidc_provider_arn n'existent plus, vérifié contre le
  # module réellement téléchargé — cf. docs/week-06-notes.md), Pod Identity
  # est désormais le seul mécanisme proposé ici. L'EBS CSI driver (eks.tf)
  # reste en IRSA de son côté (ce module-là le supporte toujours) — deux
  # mécanismes différents pour deux modules différents, pas un choix cohérent
  # à faire nous-mêmes.
  #
  # Nécessite l'addon eks-pod-identity-agent (ajouté dans eks.tf) pour
  # fonctionner réellement au runtime.
  create_pod_identity_association = true
  namespace                       = "karpenter"
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  # v1.0.6 était la dernière version stable connue au moment où ce fichier a
  # été écrit — vérifié contre les releases GitHub le 2026-09-17 : v1.14.1
  # est sortie depuis. Toujours l'API v1 stable (karpenter.sh/v1,
  # karpenter.k8s.aws/v1, cf. NodePool/EC2NodeClass plus bas), donc pas de
  # changement de schéma attendu sur les manifestes ci-dessous.
  version = "1.14.1"

  values = [
    yamlencode({
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
      # Pas d'annotation IRSA sur le ServiceAccount (contrairement à l'EBS CSI
      # driver, cf. eks.tf) : en Pod Identity, l'association namespace+SA+rôle
      # se fait via un objet API EKS séparé, créé automatiquement par
      # `module.karpenter` (create_pod_identity_association=true ci-dessus) —
      # le nom de SA par défaut du chart ("karpenter") matche déjà la valeur
      # par défaut de la variable `service_account` du sous-module.
      # Le contrôleur lui-même tourne sur le node group système (eks.tf), pas
      # sur un nœud GPU qu'il n'a pas encore le droit de provisionner tant
      # qu'il n'est pas démarré — dépendance circulaire classique, résolue en
      # l'épinglant explicitement au node group non-GPU.
      nodeSelector = {
        role = "system"
      }
    })
  ]

  depends_on = [module.eks, module.karpenter]
}

# EC2NodeClass : QUOI lancer (AMI, sous-réseaux, security groups, rôle IAM
# des nœuds). amiFamily=AL2 : Karpenter choisit automatiquement la variante
# AMI "accelerated" (drivers NVIDIA + nvidia-container-runtime préinstallés)
# quand le type d'instance a un GPU — pas besoin d'épingler un AMI ID à la
# main comme sur kind (cf. docs/week-03-notes.md, tout le passthrough manuel
# n'existe que parce que kind n'a pas cette AMI).
resource "kubectl_manifest" "gpu_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu"
    }
    spec = {
      amiFamily = "AL2"
      role      = module.karpenter.node_iam_role_name
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = module.eks.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = module.eks.cluster_name } }
      ]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "100Gi" # poids du modèle (~4 Go pour Mistral-7B AWQ) + marge cache/logs
            volumeType          = "gp3"
            deleteOnTermination = true
          }
        }
      ]
    }
  })

  depends_on = [helm_release.karpenter]
}

# NodePool : QUAND et COMBIEN. Un seul pool GPU, contraint au type d'instance
# du README (g5.xlarge, A10G 24 Go) plutôt qu'une famille entière — ce lab n'a
# jamais eu besoin de plus d'un GPU à la fois (cf. benchmarking semaine 4).
#
# Taint nvidia.com/gpu:NoSchedule posé ici pour de vrai : c'est exactement la
# toleration ajoutée sur vllm-server en semaine 4 (kubernetes/deployment.yaml)
# par anticipation de cette semaine — sur kind (un seul nœud), l'appliquer
# aurait cassé coredns/ingress-nginx/KEDA/Prometheus/Grafana ; ici, le node
# group système (eks.tf) les héberge séparément, donc plus de conflit.
resource "kubectl_manifest" "gpu_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "nvidia.com/gpu.present" = "true" # même label que sur kind (kubernetes/deployment.yaml nodeAffinity) — aucun changement côté manifeste applicatif
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu"
          }
          requirements = [
            { key = "node.kubernetes.io/instance-type", operator = "In", values = [var.gpu_instance_type] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }, # pas de spot : un serving GPU interrompu en cours de génération dégrade l'expérience ; le lab n'a qu'un seul GPU actif à la fois de toute façon
          ]
          taints = [
            { key = "nvidia.com/gpu", effect = "NoSchedule" }
          ]
        }
      }
      limits = {
        cpu = "8" # 2x g5.xlarge (4 vCPU chacune) au maximum — ce lab n'a jamais eu besoin de plus d'un GPU à la fois
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "5m" # scale-to-zero du GPU après 5 min d'inactivité — les g5.xlarge coûtent cher à laisser tourner pour rien
      }
    }
  })

  depends_on = [kubectl_manifest.gpu_node_class]
}
