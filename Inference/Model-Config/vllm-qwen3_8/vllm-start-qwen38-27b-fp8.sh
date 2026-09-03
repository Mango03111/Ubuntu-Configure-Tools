#!/bin/bash
# vLLM serve: Qwen3.8-27B-FP8 on 4x RTX 4090
# Usage: bash ~/vllm-start-qwen38-27b-fp8.sh
cd ~
export CUDA_VISIBLE_DEVICES=0,1,2,3
exec ./vllm-env/bin/vllm serve /home/antl/llm_model/Qwen3.8-27B-FP8 \
  --host 0.0.0.0 \
  --port 8000 \
  --served-model-name qwen-local \
  --trust-remote-code \
  --dtype auto \
  --max-model-len 262144 \
  --max-num-batched-tokens 8192 \
  --max-num-seqs 8 \
  --gpu-memory-utilization 0.92 \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --limit-mm-per-prompt.image 4 \
  --limit-mm-per-prompt.video 0 \
  --tool-call-parser qwen3_xml \
  --reasoning-parser qwen3 \
  --tensor-parallel-size 4 \
  --disable-custom-all-reduce
