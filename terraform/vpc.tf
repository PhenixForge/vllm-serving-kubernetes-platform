# VPC dédié plutôt que le VPC par défaut du compte : sous-réseaux privés pour
# les nœuds (workers jamais exposés directement), sous-réseaux publics pour
# les NAT Gateways et l'Ingress. 3 AZ pour rester dans les bonnes pratiques
# EKS (le control plane et les futurs quorums de composants HA en dépendent),
# même si Karpenter ne provisionnera qu'un nœud GPU à la fois dans ce lab.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]     # 10.0.0.0/20, 10.0.16.0/20, 10.0.32.0/20
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 8)] # 10.0.128.0/20, ...

  enable_nat_gateway   = true
  single_nat_gateway   = true # un seul NAT (pas un par AZ) : coût plutôt que HA réseau parfaite pour ce lab
  enable_dns_hostnames = true

  # Tags requis par le contrôleur AWS Load Balancer et par Karpenter pour la
  # découverte automatique des sous-réseaux (pas besoin de les lister à la main
  # dans le NodePool/EC2NodeClass, cf. karpenter.tf).
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
