# Control plane EKS + UN SEUL node group managé, non-GPU ("système") : juste
# assez pour héberger CoreDNS, le contrôleur Karpenter lui-même, et les
# workloads non-GPU (ingress-nginx, Prometheus/Grafana/DCGM, KEDA — les mêmes
# manifestes que sur kind, cf. kubernetes/). Les nœuds GPU ne sont PAS un
# node group Terraform : Karpenter les provisionne à la demande
# (karpenter.tf) — c'est tout l'intérêt par rapport au node group GPU fixe
# qu'on aurait pu écrire ici.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  # v21 a renommé la plupart des variables "cluster_*" en supprimant le
  # préfixe (name, kubernetes_version, endpoint_public_access, addons) — les
  # OUTPUTS gardent eux le préfixe cluster_ (cluster_name, cluster_endpoint,
  # ... cf. outputs.tf). Vérifié contre le module réellement téléchargé
  # (.terraform/modules/eks/variables.tf), pas contre la mémoire de
  # l'assistant — cf. docs/week-06-notes.md.
  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Accès public au control plane pour ce lab (kubectl depuis n'importe où) ;
  # à restreindre à des CIDR précis (bureau, VPN) avant tout usage au-delà
  # d'un apprentissage solo — cf. terraform/README.md.
  endpoint_public_access = true

  enable_irsa = true # requis pour le rôle IAM de l'EBS CSI driver (karpenter.tf est lui passé en Pod Identity, cf. plus bas)

  addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent = true
      # Active l'enforcement natif des NetworkPolicy côté VPC CNI (EKS >= 1.25).
      # Les manifestes kubernetes/network-policy.yaml, écrits en semaine 5 et
      # inertes sur kindnetd (pas de contrôleur de policy), seront RÉELLEMENT
      # appliqués ici, sans aucune modification.
      configuration_values = jsonencode({
        env = {
          ENABLE_NETWORK_POLICY = "true"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent = true
      # iam_role_arn -> arn : renommé dans le module v6 (cf. ebs_csi_irsa ci-dessous).
      service_account_role_arn = module.ebs_csi_irsa.arn
    }
    # Requis à l'exécution pour que l'association Pod Identity de Karpenter
    # (karpenter.tf, create_pod_identity_association) fonctionne réellement —
    # cet agent injecte les credentials dans les pods, faute de quoi
    # l'association existe côté API EKS mais n'a aucun effet.
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_groups = {
    system = {
      instance_types = var.system_node_instance_types
      min_size       = 1
      max_size       = 3
      desired_size   = 2 # 2, pas 1 : évite un point de panne unique sur CoreDNS/le contrôleur Karpenter

      # Pas de nvidia.com/gpu ici — ce node group n'a jamais de GPU, donc pas
      # besoin des tolerations posées sur vllm-server (kubernetes/deployment.yaml).
      labels = {
        role = "system"
      }
    }
  }

  # Tag de découverte Karpenter sur le cluster lui-même (recherché par le
  # NodePool/EC2NodeClass) — en plus des tags subnet posés dans vpc.tf.
  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

module "ebs_csi_irsa" {
  # v6 a renommé ce sous-module (retiré le suffixe -eks) et sa variable
  # role_name -> name — vérifié contre .terraform/modules/, pas la mémoire.
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name                  = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
