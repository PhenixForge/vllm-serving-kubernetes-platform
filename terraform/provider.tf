provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

# Configurés une fois le cluster créé (data sources ci-dessous) pour que les
# providers kubernetes/helm puissent parler au control plane EKS sans
# dépendre d'un `aws eks update-kubeconfig` manuel préalable.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  # helm provider v3 : `kubernetes` est un attribut objet (nested attribute,
  # syntaxe `=`), plus un bloc imbriqué comme en v2 — breaking change de la
  # migration vers le terraform-plugin-framework, vérifié contre le schéma
  # réel du provider (`terraform providers schema -json`), pas la mémoire.
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
  apply_retry_count      = 5
}
