#!/bin/bash
set -euo pipefail

# vLLM Docker serve: Qwen3.8-27B-FP8 on 4x RTX 4090 with tensor parallelism
# Usage: bash ~/vllm-start-qwen38-27b-fp8-docker-tp4.sh
readonly CONTAINER_NAME="vllm-qwen3.8-27b-fp8"
readonly IMAGE_NAME="vllm/vllm-openai:v0.27.1"
readonly MODEL_DIR="/home/antl/llm_model/Qwen3.8-27B-FP8"
readonly CONTAINER_MODEL_DIR="/models/Qwen3.8-27B-FP8"

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
  --gpus '"device=0,1,2,3"' \
  --ipc host \
  --publish 8000:8000 \
  --volume "${MODEL_DIR}:${CONTAINER_MODEL_DIR}:ro" \
  "${IMAGE_NAME}" \
  "${CONTAINER_MODEL_DIR}" \
  --host 0.0.0.0 \
  --port 8000 \
  --served-model-name qwen38-27b \
  --trust-remote-code \
  --dtype auto \
  --max-model-len 262144 \
  --max-num-batched-tokens 8192 \
  --max-num-seqs 8 \
  --gpu-memory-utilization 0.94 \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --limit-mm-per-prompt.image 10 \
  --limit-mm-per-prompt.video 0 \
  --tool-call-parser qwen3_xml \
  --reasoning-parser qwen3 \
  --tensor-parallel-size 4
