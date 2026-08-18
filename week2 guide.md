# Guide Complet : Déploiement Local de vLLM avec Mistral-7B sur Fedora 44 + Kind

---

## **Objectif**

Déployer un environnement **vLLM + Mistral-7B** en local sur Fedora 44, avec un cluster Kubernetes (`kind`) pour préparer le déploiement sur un cluster réel.

---

## **Prérequis**

- Fedora 44
- Carte graphique NVIDIA RTX 4060 (8 Go VRAM)
- Pilotes NVIDIA installés (`nvidia-smi` doit fonctionner)
- Podman installé

---

## **Étapes pour vLLM en Local (Podman)**

### 1️⃣ **Préparation du conteneur Podman**

**Problème** : `dnf config-manager` ne fonctionne pas pour ajouter le dépôt NVIDIA.  
**Solution** : Montage manuel des périphériques et bibliothèques NVIDIA.

#### **Commandes**

```bash
# Crée un dossier pour le Containerfile
mkdir -p ~/git/vllm-serving-kubernetes-platform/container
cd ~/git/vllm-serving-kubernetes-platform/container

# Crée le Containerfile
vi Containerfile
```

#### **Contenu du `Containerfile**`

```dockerfile
FROM docker.io/vllm/vllm-openai:v0.20.2

LABEL maintainer="Julien P. <PhenixForge>"
LABEL description="vLLM serving Mistral-7B-v0.1-AWQ - optimized for 8GB VRAM"

CMD ["TheBloke/Mistral-7B-Instruct-v0.1-AWQ", "--quantization", "awq_marlin", "--max-model-len", "880", "--gpu-memory-utilization", "0.6", "--trust-request-chat-template"]
```

---

### 2️⃣ **Téléchargement du modèle Mistral-7B-v0.1-AWQ**

```bash
# Installe git-lfs
sudo dnf install -y git-lfs
git lfs install

# Télécharge le modèle
mkdir -p ~/models
git clone https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.1-AWQ ~/models/Mistral-7B-Instruct-v0.1-AWQ
```

---

### 3️⃣ **Build et lancement du conteneur Podman**

```bash
# Build l'image
podman build -t vllm-mistral-7b-v01 .

# Lance le conteneur
podman run --rm --privileged \
  -v /dev/nvidia0:/dev/nvidia0 \
  -v /dev/nvidiactl:/dev/nvidiactl \
  -v /dev/nvidia-modeset:/dev/nvidia-modeset \
  -v /dev/nvidia-uvm:/dev/nvidia-uvm \
  -v /dev/nvidia-uvm-tools:/dev/nvidia-uvm-tools \
  -v /usr/lib64:/usr/lib64:ro \
  -v /usr/bin/nvidia-smi:/usr/bin/nvidia-smi:ro \
  -v ~/models:/models \
  -p 8000:8000 \
  -e LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH \
  -e CUDA_HOME=/usr/local/cuda \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0 \
  vllm-mistral-7b-v01
```

---

### 4️⃣ **Tests des endpoints vLLM**

```bash
# Healthcheck
curl --ipv4 http://localhost:8000/health

# Liste des modèles
curl --ipv4 http://localhost:8000/v1/models

# Completions
curl --ipv4 -X POST http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "TheBloke/Mistral-7B-Instruct-v0.1-AWQ", "prompt": "Bonjour", "max_tokens": 10}'

# Chat Completions (avec chat_template)
curl --ipv4 -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "TheBloke/Mistral-7B-Instruct-v0.1-AWQ",
    "messages": [{"role": "user", "content": "Bonjour"}],
    "max_tokens": 10,
    "chat_template": "{{ \"<s>\" + \"[INST] \" + message.content + \" [/INST]\" if message.role == \"user\" else message.content + \"</s>\" + \"\\n\" }}"
  }'
```

---

## **Étapes pour Kubernetes Local (Kind)**

### 1️⃣ **Installation de `kind**`

```bash
# Télécharge kind (version v0.23.0)
curl -Lo ./kind https://github.com/kubernetes-sigs/kind/releases/download/v0.23.0/kind-linux-amd64

# Installe kind
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Vérifie l'installation
kind --version
```

---

### 2️⃣ **Création du cluster Kubernetes**

```bash
# Crée un cluster nommé vllm-cluster
kind create cluster --name vllm-cluster
```

---

### 3️⃣ **Configuration de `kubectl**`

```bash
# Crée le dossier .kube
mkdir -p ~/.kube

# Exporte le kubeconfig du cluster kind
kind get kubeconfig --name vllm-cluster > ~/.kube/config

# Vérifie les permissions
chmod 600 ~/.kube/config

# Vérifie que kubectl fonctionne
kubectl get nodes
```

---

## **Résumé des commandes clés**

| Étape                    | Commande                                                                                                       | Description                    |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| Téléchargement du modèle | `git clone https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.1-AWQ ~/models/Mistral-7B-Instruct-v0.1-AWQ` | Télécharge Mistral-7B-v0.1-AWQ |
| Build de l'image         | `podman build -t vllm-mistral-7b-v01 .`                                                                        | Crée l'image Podman            |
| Lancement du conteneur   | `podman run --rm --privileged -v ... vllm-mistral-7b-v01`                                                      | Lance vLLM en local            |
| Test de l'API            | `curl --ipv4 -X POST http://localhost:8000/v1/completions ...`                                                 | Teste l'API vLLM               |
| Installation de kind     | `curl -Lo ./kind https://github.com/kubernetes-sigs/kind/releases/download/v0.23.0/kind-linux-amd64`           | Télécharge kind                |
| Création du cluster      | `kind create cluster --name vllm-cluster`                                                                      | Crée un cluster Kubernetes     |
| Configuration de kubectl | `kind get kubeconfig --name vllm-cluster > ~/.kube/config`                                                     | Configure kubectl              |


---

## **Prochaines étapes**

- **Valider la semaine 1** : Commit et push du `Containerfile` et du `README.md` dans ton dépôt.
- **Démarrer la semaine 2** : Créer les manifests Kubernetes (`deployment.yaml`, `service.yaml`) pour déployer vLLM sur ton cluster `kind`.

---

## **Dépannage**

### Si `kubectl get nodes` échoue :

1. Vérifie que le cluster est bien créé :
  ```bash
   kind get clusters
  ```
2. Vérifie que `kubectl` est installé :
  ```bash
   which kubectl || sudo dnf install -y kubectl
  ```
3. Vérifie les permissions du fichier `~/.kube/config` :
  ```bash
   ls -l ~/.kube/config
  ```

### Si le conteneur Podman échoue :

1. Vérifie les logs :
  ```bash
   podman logs <ID_DU_CONTENEUR>
  ```
2. Vérifie que le modèle est téléchargé :
  ```bash
   ls -lh ~/models/Mistral-7B-Instruct-v0.1-AWQ/
  ```