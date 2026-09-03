#!/bin/bash
set -euo pipefail

# vLLM Docker serve: Qwen3.8-27B-NVFP4 on GPU 2
# Usage: bash ~/vllm-start-qwen38-27b-nvfp4-docker.sh
readonly CONTAINER_NAME="vllm-qwen3.8-27b-nvfp4"
readonly IMAGE_NAME="vllm/vllm-openai:v0.27.1"
readonly MODEL_DIR="/home/antl/llm_model/Qwen3.8-27B-NVFP4"
readonly CONTAINER_MODEL_DIR="/models/Qwen3.8-27B-NVFP4"

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  if [[ "$(docker container inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")" == "true" ]]; then
    printf 'Container %s is already running; stop it before recreating it with the current configuration.\n' "${CONTAINER_NAME}" >&2
    exit 1
  fi

  # Docker cannot update GPU or vLLM arguments on an existing container.
  docker container rm "${CONTAINER_NAME}" >/dev/null
fi

exec docker run --detach \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --gpus '"device=2"' \
  --ipc host \
  --publish 8001:8001 \
  --volume "${MODEL_DIR}:${CONTAINER_MODEL_DIR}:ro" \
  "${IMAGE_NAME}" \
  "${CONTAINER_MODEL_DIR}" \
  --host 0.0.0.0 \
  --port 8001 \
  --served-model-name qwen38-27b-nvfp4 \
  --trust-remote-code \
  --dtype auto \
  --kv-cache-dtype fp8 \
  --max-model-len 4096 \
  --max-num-batched-tokens 8192 \
  --max-num-seqs 8 \
  --gpu-memory-utilization 0.96 \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --limit-mm-per-prompt.image 10 \
  --limit-mm-per-prompt.video 0 \
  --tool-call-parser qwen3_xml \
  --reasoning-parser qwen3 \
  --tensor-parallel-size 1
