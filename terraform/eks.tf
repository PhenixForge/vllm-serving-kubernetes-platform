# Control plane EKS + UN SEUL node group managé, non-GPU ("système") : juste
# assez pour héberger CoreDNS, le contrôleur Karpenter lui-même, et les
# workloads non-GPU (ingress-nginx, Prometheus/Grafana/DCGM, KEDA — les mêmes
# manifestes que sur kind, cf. kubernetes/). Les nœuds GPU ne sont PAS un
# node group Terraform : Karpenter les provisionne à la demande
# (karpenter.tf) — c'est tout l'intérêt par rapport au node group GPU fixe
# qu'on aurait pu écrire ici.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Accès public au control plane pour ce lab (kubectl depuis n'importe où) ;
  # à restreindre à des CIDR précis (bureau, VPN) avant tout usage au-delà
  # d'un apprentissage solo — cf. terraform/README.md.
  cluster_endpoint_public_access = true

  enable_irsa = true # requis pour les rôles IAM du contrôleur Karpenter, de l'EBS CSI driver, etc. (karpenter.tf)

  cluster_addons = {
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
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
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
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
