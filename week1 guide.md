# Guide Complet : Déploiement de vLLM avec Mistral-7B sur Fedora 44 (RTX 4060, 8 Go VRAM)

---

## **Objectif**

Déployer un serveur local **vLLM** pour servir le modèle **Mistral-7B-Instruct-v0.1-AWQ** sur une workstation Fedora 44 avec une **RTX 4060 (8 Go VRAM)**, accessible via une API OpenAI-compatible sur `http://localhost:8000`.

---

## **Prérequis**

- **Système** : Fedora 44 (avec Wayland)
- **Matériel** : Carte graphique NVIDIA RTX 4060 (8 Go VRAM)
- **Pilotes NVIDIA** : Installés et fonctionnels (`nvidia-smi` doit afficher les infos de la carte)
- **Podman** : Installé et configuré
- **Modèle** : Mistral-7B-Instruct-v0.1-AWQ (téléchargé dans `~/models/`)

>[!WARNING]
>**Une carte graphique 8Go impose des limites techniques.**
> 
>Déployer Kubernetes sous Linux limite les possibilités, même avec une carte nVidia RTX.

>[!WARNING]
>**Une carte graphique 8Go impose des limites techniques.**

---

## **Étapes Clés et Problèmes Résolus**

### 1️⃣ **Préparation du conteneur Podman**

**Problème** : `dnf config-manager` ne fonctionne pas sur Fedora 44 pour ajouter le dépôt NVIDIA.  
**Solution** : Montage manuel des périphériques et bibliothèques NVIDIA.

- **Périphériques NVIDIA** : `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-modeset`, `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools`
- **Bibliothèques** : `/usr/lib64/libnvidia*`, `/usr/lib64/libcuda*`, `/usr/bin/nvidia-smi`
- **Mode privilégié** : Utilisation de `--privileged` pour contourner les restrictions de permissions.

---

### 2️⃣ **Choix du Modèle et Configuration du Containerfile**

**Problème** :

- Mistral-7B-v0.2-AWQ consomme trop de VRAM (~4.5 Go + cache).
- Le modèle `v0.1-AWQ` est plus léger (~3.8 Go) et compatible avec 8 Go.

**Solution** :

- **Modèle** : `TheBloke/Mistral-7B-Instruct-v0.1-AWQ`
- **Quantification** : `awq_marlin` (optimisé pour NVIDIA, +20-30% de performance)

---

### 3️⃣ **Gestion de la Mémoire GPU**

**Problème** :

- vLLM essaie d’allouer **6.09 Go** pour le cache KV, mais seule **5.84 Go** sont libres.
- **CUDA Graph Memory Profiling** (activé par défaut depuis v0.21.0) réduit la mémoire disponible pour le cache.

**Solutions appliquées** :

1. **Désactivation du profiling** : `-e VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0`
2. **Réduction de `max_model_len**` : `--max-model-len 880` (au lieu de 1024 ou 2048)
3. **Réduction de `gpu_memory_utilization**` : `--gpu-memory-utilization 0.6` (60% de 7.62 Go = 4.57 Go alloués)

---

### 4️⃣ **Problème de Connexion IPv6**

**Problème** : vLLM écoute sur **IPv4** (`0.0.0.0:8000`), mais `curl` essaie d’abord **IPv6** (`::1`), ce qui échoue.

**Solution** : Forcer IPv4 avec `--ipv4` dans les requêtes `curl`.

---

### 5️⃣ **Téléchargement du Modèle**

Le modèle doit être téléchargé dans `~/models/` avant de lancer le conteneur.

---

## **Fichiers et Commandes**

---

### 🔹 **Containerfile**

```dockerfile
# Docker Containerfile
FROM docker.io/vllm/vllm-openai:v0.20.2

LABEL maintainer="Julien P. <PhenixForge>"
LABEL description="vLLM serving Mistral-7B-v0.1-AWQ - optimized for 8GB VRAM"

# Commande pour lancer vLLM avec Mistral-7B-v0.1-AWQ
CMD ["TheBloke/Mistral-7B-Instruct-v0.1-AWQ", "--quantization", "awq_marlin", "--max-model-len", "880", "--gpu-memory-utilization", "0.6"]
```

---

### 🔹 **Téléchargement du Modèle**

```bash
# Installe git-lfs (si ce n'est pas déjà fait)
sudo dnf install -y git-lfs
git lfs install

# Télécharge le modèle dans ~/models
mkdir -p ~/models
git clone https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.1-AWQ ~/models/Mistral-7B-Instruct-v0.1-AWQ
```

---

### 🔹 **Build de l'Image**

```bash
cd ~/git/vllm-serving-kubernetes-platform/container
podman build -t vllm-mistral-7b-v01 .
```

---

### 🔹 **Lancement du Conteneur**

```bash
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

### 🔹 **Test de l'API**

```bash
# Attends que vLLM soit prêt (vérifie les logs avec podman logs -f <ID>)
# Puis teste avec :
curl --ipv4 -X POST http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "TheBloke/Mistral-7B-Instruct-v0.1-AWQ", "prompt": "Bonjour, comment ça va ?", "max_tokens": 10}'
```

---

## **Points Clés à Retenir**

1. **Montage des périphériques NVIDIA** : Indispensable pour l’accès GPU sous Podman.
2. **Désactivation du CUDA Graph Profiling** : `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` libère de la mémoire pour le cache KV.
3. **Réduction de `max_model_len**` : `880` est la taille max compatible avec ta VRAM disponible.
4. **Forcer IPv4** : `curl --ipv4` évite les problèmes de connexion IPv6.
5. **Modèle léger** : `Mistral-7B-v0.1-AWQ` consomme moins de VRAM que la v0.2.

---

## **Résultat Final**

✅ **Un conteneur Podman fonctionnel** qui :

- Sert **Mistral-7B-v0.1-AWQ** en local.
- Utilise **ton GPU RTX 4060** (8 Go VRAM).
- Répond aux requêtes via une **API OpenAI-compatible** sur `http://localhost:8000`.
- Est **optimisé pour éviter les erreurs de mémoire**.

---

## 📌 **Dépannage**

### Si le conteneur ne démarre pas :

1. **Vérifie les logs** :
  ```bash
   podman logs <ID_DU_CONTENEUR>
  ```
2. **Vérifie que le modèle est téléchargé** :
  ```bash
   ls -lh ~/models/Mistral-7B-Instruct-v0.1-AWQ/
  ```

### Si `curl` échoue :

1. **Vérifie que vLLM est prêt** :
  ```bash
   curl --ipv4 http://localhost:8000/health
  ```
  &nbsp;
2. **Vérifie que le modèle est chargé** :
  ```bash
   curl --ipv4 http://localhost:8000/v1/models
  ```
  &nbsp;

---

## 🔗 **Ressources Utiles**

- [Documentation vLLM](https://docs.vllm.ai/)
- [Modèle Mistral-7B-Instruct-v0.1-AWQ sur Hugging Face](https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.1-AWQ)
- [Guide Podman pour NVIDIA GPU](https://github.com/containers/podman/blob/main/docs/tutorials/nvidia_gpu.md)