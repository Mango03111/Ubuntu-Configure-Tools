#!/usr/bin/env bash
set -euo pipefail

# 需与 start_qwen36_200k.sh 的 WORK_DIR 保持一致（可用环境变量覆盖）。
WORK_DIR="${WORK_DIR:-/home/antl/vllm-qwen36-ct}"
PID_FILE="$WORK_DIR/logs/vllm_qwen36_ct_8k.pid"
SERVED_MODEL="qwen3.6-35b-a3b-ct4"

stop_pid() {
  local pid="$1"
  local cmdline
  cmdline="$(ps -p "$pid" -o args= || true)"
  if [[ -n "$cmdline" ]] && echo "$cmdline" | grep -q "vllm serve" && echo "$cmdline" | grep -q "$SERVED_MODEL"; then
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" || true
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" || true
      fi
    fi
  else
    echo "Skip PID $pid (not the target qwen3.6 vLLM service)"
  fi
}

stop_port_8000_target() {
  local pids cmdline
  pids="$(ss -ltnp 2>/dev/null | awk '/:8000 / {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | sort -u)"
  if [[ -n "${pids:-}" ]]; then
    while read -r p; do
      [[ -z "$p" ]] && continue
      cmdline="$(ps -p "$p" -o args= || true)"
      if [[ -n "$cmdline" ]] && echo "$cmdline" | grep -q "vllm serve" && echo "$cmdline" | grep -q "$SERVED_MODEL"; then
        stop_pid "$p"
      fi
    done <<< "$pids"
  fi
}

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" || true)"
  if [[ -n "${pid:-}" ]]; then
    stop_pid "$pid"
  fi
  rm -f "$PID_FILE"
fi

# Always do a port-based pass to handle stale pid files safely.
stop_port_8000_target

# If target process already exited but a non-target process is still using 8000, fail clearly.
if ss -ltnp | grep -q ':8000'; then
  echo "Port 8000 still listening:" >&2
  ss -ltnp | grep ':8000' >&2
  echo "Refuse to kill non-target process. Stop it manually if needed." >&2
  exit 1
fi

echo "Port 8000 is free"
