# Extensions vLLM — Vault & Packer

Contexte pour Claude Code : projet `vllm-serving-kubernetes-platform`. Semaines 1 à 5 terminées (dont sécurisation semaine 5 : SecurityContext non-root, capabilities drop ALL, NetworkPolicies écrites et testées). État au 2026-09-21 — semaine 6 en cours : Terraform EKS/Karpenter écrit et validé (`init`/`validate`/`plan`), pas encore appliqué (pas de credentials AWS, pour ne pas engager de coût réel). Ces deux extensions sont volontairement tenues hors du cœur de roadmap (semaines 1-6 + extensions déjà actées : serveur MCP sur les métriques Prometheus/DCGM, RAG sur la doc du projet, harnais d'évaluation type RAGAS) — à ne prendre qu'une fois le socle stable, pas en remplacement de la suite prévue. Le projet s'étale sur plusieurs mois : re-vérifier les versions (Kubernetes, AMI, Vault, Packer) au moment de chaque session plutôt que de réutiliser celles de ce document.

---

## 1. Vault — secrets dynamiques

### 1a. Vault Secrets Operator — remplacer les K8s Secrets statiques de la semaine 5

**Scope** : synchroniser depuis une instance Vault réelle (mode dev suffisant, ou conteneur comme le reste du projet) les secrets actuellement posés en dur en semaine 5 (clé API/JWT du service, futur token HuggingFace).

**Étapes** :
1. Déployer Vault (dev server ou conteneur), activer le moteur `kv-v2`.
2. Écrire une policy scopant l'accès en lecture seule au chemin du secret vLLM.
3. Installer le Vault Secrets Operator (Helm) dans le cluster (kind ou EKS).
4. Créer les CRD `VaultConnection`, `VaultAuth`, `VaultStaticSecret` pointant vers le secret.
5. Vérifier la synchronisation automatique et la rotation dans le Secret K8s généré.

**Effort** : ~2-3h, essentiellement déclaratif.

**Lien avec Vault Associate** : couvre les objectifs 2 (policies) et 5 (secrets engines) ; le Vault Secrets Operator est nommément cité dans le programme officiel de l'examen (obj. 9b) — la session de projet double comme révision.

**Signal portfolio** : « secrets statiques remplacés par une synchronisation Vault déclarative dans le cluster de serving ».

---

### 1b. AWS Secrets Engine — credentials Terraform dynamiques pour Karpenter/EKS

**Scope** : au lieu d'une clé IAM statique pour que Terraform provisionne EKS/Karpenter, Vault génère des credentials AWS de courte durée à la demande, avec révocation automatique en fin de TTL.

**Étapes** :
1. Activer le secrets engine `aws`.
2. Définir un rôle Vault avec une policy IAM strictement scopée au provisioning EKS (pas de wildcard).
3. Générer un lease, l'injecter dans l'environnement Terraform (variables d'environnement ou provider `aws` configuré via Vault).
4. Observer la révocation automatique et retenter un `plan` après expiration pour vérifier le comportement.

**Effort** : ~2h. **Prérequis** : avoir déjà fait un premier `apply` réel du Terraform EKS — cette tâche vient après, pas avant.

**Lien avec Vault Associate** : objectifs 4 (leases) et 5b (secrets dynamiques vs statiques) — c'est l'exemple canonique du programme, appliqué à ton propre provisioning plutôt qu'à un cas d'école.

**Signal portfolio** : le plus fort des deux côté entretien AI Platform. « Mes credentials de provisioning ne sont jamais stockés en dur, ils sont émis à la demande et expirent automatiquement » — directement transposable à l'identité éphémère des agents (workloads agentiques).

---

### 1c. Optionnel, seulement s'il reste du temps : Vault Agent Injector sur le pod vLLM

Sidecar Vault Agent injectant dynamiquement la clé API/JWT du service dans le pod, au lieu d'un Secret monté statiquement. Même logique que 1a mais au niveau du pod applicatif plutôt que du secret d'infra. Priorité basse — 1a couvre déjà l'essentiel du signal Vault côté Kubernetes.

---

### 1d. Identité des agents IA — un agent, une identité Vault, des credentials éphémères

**Idée** : c'est l'angle qui relie Vault au reste du projet. Les extensions MCP/RAG/évaluation sont des workloads *agentiques* : ils appellent Prometheus, Qdrant, vLLM, parfois AWS. Plutôt que de leur donner des clés statiques partagées, chaque agent obtient une identité propre auprès de Vault et des credentials de courte durée, limités à ce qu'il a le droit de faire.

**Scope** :
- Méthode d'auth `kubernetes` : le ServiceAccount du pod (`mcp-server`, `rag-ingestion`, `evaluation`) est l'identité de l'agent — pas de secret de bootstrap à distribuer.
- Une policy Vault par agent, en moindre privilège (ex. le serveur MCP lit uniquement le chemin du token Prometheus ; l'ingestion RAG écrit uniquement sur Qdrant).
- Credentials dynamiques avec TTL court (moteur `aws` de la 1b, ou moteur `database` pour pgvector si retenu), renouvelés par le Vault Agent/VSO, jamais stockés dans l'image ni dans un Secret statique.
- Device d'audit activé : on peut répondre à « quel agent a lu quoi, quand ? », donc démontrer la traçabilité des actions d'un agent.
- Démonstration de révocation : révoquer le lease d'un agent et montrer que son accès s'arrête immédiatement, sans redéploiement.

**Prérequis** : au moins le serveur MCP (Phase A des extensions) déployé — sinon il n'y a pas d'agent à identifier. Se place donc après 1a, et s'appuie sur la 1b pour les credentials AWS.

**Effort** : ~3h, un peu plus si on ajoute le moteur `database`.

**Signal portfolio** : « chaque agent IA a sa propre identité, ses droits minimaux, des credentials qui expirent, et une piste d'audit » — c'est le sujet de gouvernance des workloads agentiques, plus rare et plus parlant en entretien AI Platform que « j'utilise Vault ».

---

## 2. Packer — image GPU pré-construite (réduction du cold start)

**Contexte** : problème déjà documenté dans le projet — un nœud Karpenter démarre, installe les pilotes NVIDIA puis télécharge l'image `vllm/vllm-openai` (plusieurs Go) avant de pouvoir servir une requête. Lié au temps de scale-up mesuré en semaine 6.

**Scope** : builder Packer (`amazon-ebs`) partant de l'AMI EKS-optimized GPU officielle (AL2023 + pilotes NVIDIA déjà inclus), avec un provisioner shell qui pré-tire l'image vLLM dans le cache containerd du nœud. Référencer la nouvelle AMI dans le `NodeClass` Karpenter (`amiSelectorTerms`).

**Étapes** :
1. Template Packer à partir de l'AMI EKS GPU officielle la plus récente (vérifier la référence exacte au moment de l'exécution, ne pas la coder en dur). Le `EC2NodeClass` de [terraform/karpenter.tf](../../terraform/karpenter.tf) utilise déjà `al2023@latest` (Kubernetes 1.36) : la base Packer doit rester sur la même famille et la même version de Kubernetes.
2. Provisioner shell : `ctr image pull` (ou équivalent containerd) de l'image vLLM utilisée par le projet.
3. Build → nouvelle AMI taguée.
4. Mise à jour du `EC2NodeClass` Karpenter pour cibler cette AMI.
5. Chronométrer le délai nœud créé → pod `Ready`, avant et après.

**Effort** : ~2-3h de build et itération de template.

**Coût réel à anticiper** : le build Packer lance une instance EC2 GPU temporaire le temps de la construction — quelques minutes facturées, une seule fois par session de build, pas en boucle.

**Critère de succès** : le chiffre avant/après, documenté comme les autres mesures du projet — preuve chiffrée plutôt qu'affirmation.

**Signal portfolio** : répond noir sur blanc à un problème déjà documenté dans le troubleshooting du projet, avec un chiffre à l'appui — matériel d'entretien direct plutôt qu'une compétence Packer générique.

---

## Recommandation de séquençage

Ne pas prendre les quatre tâches d'un coup. Par ordre de valeur pour la cible AI Platform :

1. **Packer (section 2)** — résout un problème déjà réel et documenté du projet, chiffre mesurable.
2. **Vault 1b (AWS Secrets Engine)** — le signal le plus différenciant, lien direct avec les postes AI Platform visés et avec la thèse identité éphémère des agents.
3. Vault 1d (identité des agents) — après le serveur MCP ; c'est le pont entre Vault et la thèse « workloads agentiques ».
4. Vault 1a — bon rapport effort/valeur, mais moins différenciant que 1b/1d.
5. Vault 1c — à laisser de côté sauf temps disponible.

Packer et Vault 1b supposent un premier `apply` réel du Terraform EKS/Karpenter de la semaine 6 — à placer après, pas avant. Vault 1d suppose le serveur MCP (Phase A) ; 1a et 1d peuvent se tester sur `kind`.

Ces extensions viennent après la fin du cœur du projet (semaines 1-12) et après les phases MCP/RAG/évaluation de [EXTENSIONS_ROADMAP.md](EXTENSIONS_ROADMAP.md), sauf 1d qui n'a besoin que de MCP.