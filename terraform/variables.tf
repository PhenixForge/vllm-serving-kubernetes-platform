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
  default     = "1.30" # aligné sur la version du cluster kind local (semaines 3-5)
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
