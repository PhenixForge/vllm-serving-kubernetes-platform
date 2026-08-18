# Semaine 5 : Sécurisation, Isolation & Production Readiness

L'objectif de cette cinquième semaine est de faire passer la plateforme d'un état "fonctionnel" à un état **sécurisé et prêt pour la production**, en verrouillant l'accès aux ressources GPU, la gestion des secrets et le réseau.

---

## **1. Authentification & Gestion de la Charge API**

### **API Gateway & Ingress Security :**
* Implémenter un filtrage par clé API (API Keys) ou jetons Bearer JWT à l'entrée de la passerelle pour restreindre l'accès à l'endpoint OpenAPI de vLLM.
* Mettre en place un **Rate Limiting** strict (via Ingress NGINX annotations, EnvoyFilter ou API Gateway) pour éviter le déni de service (DoS) sur le modèle.

## **2. Isolation Réseau (Network Policies)**

### **Verrouillage du Namespace `vllm` :**
* Appliquer des **NetworkPolicies** strictes pour refuser tout le trafic entrant/sortant non sollicité.
* Ne permettre le trafic entrant vers le pod vLLM **que depuis le contrôleur Ingress**.
* Restreindre le trafic sortant (*egress*) aux seuls points de terminaison nécessaires (ex. téléchargement Hugging Face ou serveur de métriques Prometheus).

## **3. Sécurisation des Workloads & Runtime Security**

### **SecurityContext du Pod & Container :**
* Appliquer le principe du moindre privilège : exécuter le conteneur vLLM sans accès `root` (`runAsNonRoot: true`, `readOnlyRootFilesystem`).
* Désactiver l'élévation de privilèges (`allowPrivilegeEscalation: false`) et supprimer toutes les capacités Kernel superflues (`capabilities: drop: ["ALL"]`).

### **Gestion des Secrets et des Jetons Hugging Face :**
* Sortir les jetons d'accès (ex. `HF_TOKEN` pour les modèles fermés/gated) des fichiers YAML/ConfigMaps et basculer sur des **Kubernetes Secrets** ou une intégration External Secrets Operator / Vault.

## **4. Haute Disponibilité & Stratégies de Robustesse**

### **Graceful Shutdown & Health Probes :**
* Ajuster les `livenessProbe` et `readinessProbe` spécifiquement pour vLLM (éviter de tuer le pod pendant le chargement initial des poids en VRAM).
* Configurer `terminationGracePeriodSeconds` pour permettre la fin d'exécution des requêtes en cours lors d'un rééquilibrage de nœud ou d'un scale-down.

### **Tolerations, NodeAffinity & Isolation Hardware :**
* Définir les `Taints` sur les nœuds GPU pour interdire aux pods système ou non critiques d'occuper la VRAM.
* Configurer `nodeAffinity` pour s'assurer que les pods vLLM ne démarrent que sur les nœuds équipés de GPU dédiés.

---

## **Livrables à produire en Semaine 5**

1. **`kubernetes/network-policy.yaml`** : Fichier d'isolation réseau.
2. **`kubernetes/secret.yaml`** (ou SealedSecret) : Stockage sécurisé du jeton Hugging Face.
3. **`kubernetes/deployment-hardened.yaml`** : Deployment vLLM intégrant le SecurityContext renforcé et les Probes optimisées.

---

# A faire
## Manifestes YAML pour les NetworkPolicies 

## Configuration du SecurityContext conteneurisé