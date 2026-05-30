#!/usr/bin/env bash
# scripts/run-local.sh
# Lance vLLM en local avec config par défaut
set -euo pipefail

MODEL="${MODEL:-TheBloke/Mistral-7B-Instruct-v0.2-AWQ}"
PORT="${PORT:-8000}"
GPU_MEM="${GPU_MEM:-0.80}"
MAX_LEN="${MAX_LEN:-2048}"
CACHE_DIR="${CACHE_DIR:-$HOME/llm-models/huggingface}"

echo "Starting vLLM server..."
echo "  Model: $MODEL"
echo "  Port:  $PORT"
echo "  GPU mem util: $GPU_MEM"

mkdir -p "$CACHE_DIR"

podman run -d \
  --name vllm-server \
  --replace \
  --security-opt=label=disable \
  --device nvidia.com/gpu=all \
  --ipc=host \
  -p "${PORT}:8000" \
  -v "${CACHE_DIR}:/root/.cache/huggingface:Z" \
  vllm-serving:latest \
  --model "$MODEL" \
  --quantization awq \
  --max-model-len "$MAX_LEN" \
  --gpu-memory-utilization "$GPU_MEM" \
  --dtype half

echo "Waiting for server to be ready..."
for i in {1..60}; do
  if curl -s -f http://localhost:${PORT}/health > /dev/null 2>&1; then
    echo "Server ready after ${i} seconds"
    exit 0
  fi
  sleep 1
done

echo "ERROR: Server did not become ready in 60 seconds"
podman logs --tail 30 vllm-server
exit 1