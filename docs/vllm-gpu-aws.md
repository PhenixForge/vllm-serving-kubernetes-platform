# vLLM sur le GPU AWS (A10G 24 Go) — arguments à revoir

> État au 2026-09-21 — **valeurs non testées sur un GPU réel**. Les noms d'options ont été vérifiés dans le code source de vLLM `v0.20.2` (l'image utilisée) ; les valeurs, elles, sont des choix raisonnés à confirmer dans les logs du premier démarrage.

## Pourquoi il faut d'autres arguments

Les arguments vLLM de l'image ([`container/Containerfile`](../container/Containerfile)) ont été réglés pour la **RTX 4060 8 Go, partagée** avec le reste de la workstation :

```
--quantization awq_marlin --max-model-len 880 --gpu-memory-utilization 0.6 --trust-request-chat-template
```

Sur un `g5.xlarge` (NVIDIA A10G, **24 Go dédiés**), les reprendre tels quels serait une erreur silencieuse : le serveur démarre, répond, et passe à côté de la quasi-totalité de la capacité — un contexte de 880 tokens et 40 % de VRAM inutilisée, sans aucun message d'erreur. C'est le même genre de piège que les autres de ce dépôt : rien ne casse, les résultats sont juste faux ou sous-optimaux (cf. [`retour-d-experience.md`](retour-d-experience.md)).

## Comment c'est appliqué

Pas de rebuild d'image : l'`ENTRYPOINT` de l'image `vllm-openai` est `vllm serve` (vérifié dans le Dockerfile v0.20.2), donc le champ `args` du pod **remplace le `CMD`** de l'image. Voir [`kubernetes-eks/deployment.yaml`](../kubernetes-eks/deployment.yaml). Le `Containerfile` et le cluster `kind` restent inchangés (une seule image, deux jeux d'arguments).

> Correction : une note précédente ([`week-06-notes.md`](week-06-notes.md)) affirmait que ce réglage exigeait « un changement d'image, pas de manifeste ». C'était faux, corrigé.

## Comparaison

| Option | RTX 4060 (`kind`, image) | A10G (EKS, `args`) | Pourquoi |
|---|---|---|---|
| `--quantization` | `awq_marlin` | `awq_marlin` | Même modèle AWQ → comparaison à modèle constant. Marlin tourne sur Ampere (A10G) comme sur Ada (4060). |
| `--dtype` | (auto) | `half` | AWQ travaille en fp16 ; le `config.json` du modèle annonce `bfloat16`. Explicite plutôt que laisser vLLM convertir avec un avertissement. |
| `--max-model-len` | 880 | 8192 | Le 880 n'existait que faute de VRAM pour le cache KV. Le `config.json` du modèle indique 32768 positions et une fenêtre glissante de 4096 : 8192 est un point de départ prudent, à monter après mesure. |
| `--gpu-memory-utilization` | 0.6 | 0.90 | Le 0.6 protégeait une workstation partagée. Ici le GPU est dédié (DCGM n'occupe pas de VRAM). Le défaut de vLLM est 0.92 ; 0.90 laisse un peu de marge. |
| `--max-num-seqs`, `--max-num-batched-tokens` | défauts | défauts | Sur ce type de GPU (< 70 Go) les défauts du serveur OpenAI sont 256 séquences et 2048 tokens par batch (code source) : pas de raison de les toucher avant d'avoir mesuré. |
| `--trust-request-chat-template` | oui | oui | Ce tokenizer n'a pas de chat template par défaut (cf. [`week-03-notes.md`](week-03-notes.md)). |

### Ordre de grandeur (calcul, pas mesure)

Cache KV de Mistral 7B : 2 (K et V) × 32 couches × 8 têtes KV × 128 dim × 2 octets ≈ **128 Kio par token**. Avec ~20 Go de budget (0.90 × ~22,5 Go utilisables), ~4,1 Go de poids AWQ et une marge pour les activations, il reste de l'ordre de **14 Go de cache KV, soit ~100 000 tokens** — contre quelques milliers sur la 4060. À comparer à la ligne de log de vLLM au démarrage (`GPU KV cache size: … tokens`) : si l'écart est grand, un des chiffres ci-dessus est faux.

## Conséquences à ne pas rater

- **Les mesures ne sont pas directement comparables** à celles de `kind` (contexte et VRAM différents). Le comparatif kind ↔ EKS doit le dire explicitement, pas le laisser croire.
- **Le seuil KEDA (5 requêtes en file par replica) est calibré sur la 4060**, où le cache KV saturait vite et la file se remplissait tôt. Avec ~100 000 tokens de cache, la file apparaît bien plus tard : le scale-out risque de ne pas se déclencher au niveau de charge prévu. À recalibrer sur la baseline réelle du A10G ([`week7 guide.md`](week7%20guide.md), étape 1) plutôt que d'ajuster la charge pour « faire scaler ».

## Variante FP16 (comparatif AWQ vs FP16 prévu au plan initial)

Le plan initial prévoit un comparatif FP16 vs AWQ sur le A10G — possible pour la première fois ici (14 Go de poids n'entraient pas sur 8 Go). Le dépôt `mistralai/Mistral-7B-Instruct-v0.1` n'est pas soumis à validation d'accès sur Hugging Face (vérifié via l'API le 2026-09-21).

```yaml
args:
- mistralai/Mistral-7B-Instruct-v0.1   # pas d'option --quantization
- --dtype=bfloat16                     # ou half ; le A10G (Ampere) supporte bf16
- --max-model-len=8192
- --gpu-memory-utilization=0.90
- --trust-request-chat-template
```

Poids ≈ 14,5 Go → il reste de l'ordre de **5 Go de cache KV (~40 000 tokens)** : nettement moins que l'AWQ, ce qui rend la file d'attente — donc le déclenchement KEDA — bien plus sensible. Le téléchargement à froid est aussi environ 3,5 fois plus lourd (impact direct sur le cold start, cf. [`week7 guide.md`](week7%20guide.md)). Une seule variable à la fois : comparer AWQ et FP16 **avec les mêmes autres arguments**.

## À vérifier au premier démarrage réel

1. Aucun avertissement de conversion de dtype dans les logs.
2. `GPU KV cache size` ≈ l'ordre de grandeur ci-dessus ; « maximum concurrency » cohérent avec `--max-model-len`.
3. Pas de `CUDA out of memory` au chargement (sinon baisser `--gpu-memory-utilization` à 0.85).
4. L'API répond sur `/v1/completions` avec le même corps de requête que sur `kind`.
