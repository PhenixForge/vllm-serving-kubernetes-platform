variable "region" {
  description = "Région AWS cible."
  type        = string
  default     = "eu-west-3" # Paris — cohérent avec le README (souveraineté/écosystème FR, modèle Mistral)
}

variable "cluster_name" {
  description = "Nom du cluster EKS."
  type        = string
  default     = "vllm-serving"
}

variable "cluster_version" {
  description = "Version Kubernetes du control plane EKS."
  type        = string
  default     = "1.36" # dernière version en support standard EKS (vérifié sur la doc AWS le 2026-09-21). Décalage volontaire avec le kind local (1.30) : ne pas figer le cloud sur une version périmée. Karpenter >= 1.13 requis pour 1.36 (chart 1.14.1 OK).
}

variable "vpc_cidr" {
  description = "CIDR du VPC dédié au cluster."
  type        = string
  default     = "10.0.0.0/16"
}

variable "gpu_instance_type" {
  description = "Type d'instance EC2 pour les nœuds GPU provisionnés par Karpenter."
  type        = string
  default     = "g5.xlarge" # NVIDIA A10G 24 Go — cf. README "Hardware (cloud)"
}

variable "system_node_instance_types" {
  description = "Types d'instance pour le node group managé 'système' (non-GPU) : CoreDNS, contrôleur Karpenter, ingress-nginx, monitoring. Karpenter a besoin d'un socle pour démarrer avant de pouvoir provisionner quoi que ce soit lui-même."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "tags" {
  description = "Tags appliqués à toutes les ressources."
  type        = map(string)
  default = {
    Project   = "vllm-serving-kubernetes-platform"
    ManagedBy = "terraform"
  }
}
