#!/usr/bin/env bash
set -euo pipefail

# 默认值可用环境变量覆盖，例如：
#   VENV_DIR=/path/to/venv MODEL_DIR=/path/to/model ./start_qwen36_200k.sh
VENV_DIR="${VENV_DIR:-/home/antl/Desktop/vllm-env}"
MODEL_DIR="${MODEL_DIR:-/home/antl/llmmodel/vllm/Qwen3.6-35B-A3B-AWQ-4bit}"
WORK_DIR="${WORK_DIR:-/home/antl/vllm-qwen36-ct}"
LOG_DIR="$WORK_DIR/logs"
LOG_FILE="$LOG_DIR/vllm_qwen36_ct_8k.log"
PID_FILE="$LOG_DIR/vllm_qwen36_ct_8k.pid"

mkdir -p "$LOG_DIR"

source "$VENV_DIR/bin/activate"

which python
python -V
command -v vllm
vllm --version

test -f "$MODEL_DIR/config.json" || { echo "Missing $MODEL_DIR/config.json" >&2; exit 1; }
test -f "$MODEL_DIR/model.safetensors.index.json" || { echo "Missing $MODEL_DIR/model.safetensors.index.json" >&2; exit 1; }

SAFETENSORS_COUNT="$(find "$MODEL_DIR" -maxdepth 1 -name "*.safetensors" | wc -l)"
if [[ "$SAFETENSORS_COUNT" != "5" ]]; then
  echo "Expected 5 safetensors shards, got $SAFETENSORS_COUNT" >&2
  exit 1
fi

if ss -ltnp | grep -q ':8000'; then
  echo "Port 8000 is already in use. Run stop_vllm.sh first."
  ss -ltnp | grep ':8000' >&2
  exit 1
fi

mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d_%H%M%S).bak" 2>/dev/null || true
touch "$LOG_FILE"

export PYTHONUNBUFFERED=1
export CUDA_VISIBLE_DEVICES=0,1
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=1

nvidia-smi

export VENV_DIR MODEL_DIR
nohup bash -lc '
source "$VENV_DIR/bin/activate"
export PYTHONUNBUFFERED=1
export CUDA_VISIBLE_DEVICES=0,1
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=1
exec vllm serve "$MODEL_DIR" \
  --served-model-name qwen3.6-35b-a3b-ct4 \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 2 \
  --max-model-len 200000 \
  --gpu-memory-utilization 0.85 \
  --reasoning-parser qwen3 \
  --language-model-only \
  --max-num-seqs 1 \
  --max-num-batched-tokens 1024
' >> "$LOG_FILE" 2>&1 &

echo $! > "$PID_FILE"
PID="$(cat "$PID_FILE")"
sleep 3
if ! ps -p "$PID" >/dev/null 2>&1; then
  echo "vLLM process exited early."
  tail -n 200 "$LOG_FILE" || true
  exit 1
fi
echo "vLLM started with PID: $PID"
echo "Log: $LOG_FILE"
