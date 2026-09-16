# Semaine 6 — migration EKS. Terraform pour l'infra AWS uniquement ; les
# manifestes Kubernetes applicatifs restent dans kubernetes/ (variantes
# EKS-spécifiques sous kubernetes-eks/, cf. terraform/README.md — le
# passthrough GPU manuel de kind n'a plus lieu d'être sur un vrai
# nvidia-container-runtime).
terraform {
  required_version = ">= 1.7"

  required_providers {
    # Versions vérifiées contre le registre Terraform le 2026-09-17 (pas
    # fiées à la mémoire de l'assistant, dont la connaissance s'arrête à
    # janvier 2026 — aws/kubernetes/helm avaient tous eu une bump majeure
    # depuis, cf. docs/week-06-notes.md pour le détail de la vérification).
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    # Pas `hashicorp/kubernetes.kubernetes_manifest` pour les CRD Karpenter
    # (NodePool/EC2NodeClass) : cette ressource a besoin que le CRD existe déjà
    # au moment du `plan`, ce qui casse quand le CRD est créé dans le même
    # apply (par le chart Helm juste au-dessus). `kubectl_manifest` n'a pas
    # cette limitation — pattern standard des exemples officiels
    # terraform-aws-modules/eks pour Karpenter.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
  }

  # Backend local par défaut (adapté à un usage solo/apprentissage) : l'état
  # atterrit dans terraform/terraform.tfstate, volontairement PAS commité
  # (cf. .gitignore) puisqu'il peut contenir des données sensibles selon les
  # ressources. Pour un usage en équipe ou en CI, basculer sur un backend S3 +
  # verrouillage DynamoDB — voir terraform/README.md.
}
