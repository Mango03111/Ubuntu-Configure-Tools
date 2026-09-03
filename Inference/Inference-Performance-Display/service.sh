#!/usr/bin/env bash
#
# service.sh — run the Inference Performance Display server in the background.
#
# The server is fully detached from the terminal (setsid + nohup), so it keeps
# running after the shell is closed. The PID is stored in server.pid and logs
# are appended to server.log, both next to this script.
#
# Usage:
#   ./service.sh start      start the server in the background
#   ./service.sh stop       stop it gracefully (flushes the usage CSV)
#   ./service.sh restart    stop + start
#   ./service.sh status     show process and endpoint state
#   ./service.sh logs       follow the server log (Ctrl+C to leave)
#
# Environment overrides (inherited by server.py):
#   SERVER_PORT, SERVER_HOST, INFERENCE_METRICS_URL, POLL_INTERVAL_MS, ...
#   e.g.  SERVER_PORT=9090 ./service.sh start
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="$SCRIPT_DIR/server.py"
PID_FILE="$SCRIPT_DIR/server.pid"
LOG_FILE="$SCRIPT_DIR/server.log"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PORT="${SERVER_PORT:-8090}"
HEALTH_URL="http://127.0.0.1:${PORT}/api/health"

log()  { printf '[service] %s\n' "$*"; }
fail() { printf '[service] ERROR: %s\n' "$*" >&2; exit 1; }

# Print the PID of the live server for this directory, or fail.
# Prefers the pid file; falls back to scanning for a python server.py whose
# working directory is this one (covers a missing or stale pid file).
running_pid() {
    local pid p cwd
    if [[ -f "$PID_FILE" ]]; then
        pid="$(tr -d '[:space:]' < "$PID_FILE" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null \
            && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'server\.py'; then
            printf '%s\n' "$pid"
            return 0
        fi
    fi
    for p in $(pgrep -f 'server\.py' 2>/dev/null); do
        cwd="$(readlink "/proc/$p/cwd" 2>/dev/null)"
        if [[ "$cwd" == "$SCRIPT_DIR" ]] \
            && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'server\.py'; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

start() {
    local pid code i tail_out
    if pid="$(running_pid)"; then
        log "already running (PID $pid)"
        return 0
    fi
    rm -f "$PID_FILE"
    [[ -f "$SERVER_PY" ]] || fail "server.py not found: $SERVER_PY"
    command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "$PYTHON_BIN not found"

    log "starting $SERVER_PY (log: $LOG_FILE) ..."
    (
        cd "$SCRIPT_DIR" || exit 1
        setsid nohup "$PYTHON_BIN" server.py >>"$LOG_FILE" 2>&1 </dev/null &
    )

    pid=""
    for i in $(seq 1 20); do
        sleep 0.5
        pid="$(running_pid || true)"
        [[ -n "$pid" ]] && break
    done
    if [[ -z "$pid" ]]; then
        tail_out="$(tail -n 5 "$LOG_FILE" 2>/dev/null)"
        fail "process did not start; last log lines: $tail_out"
    fi
    echo "$pid" > "$PID_FILE"
    log "server started (PID $pid)"

    # Any HTTP answer proves the dashboard is up; 503 only means the upstream
    # metrics endpoint is currently unreachable.
    code=""
    for i in $(seq 1 20); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$HEALTH_URL" || true)"
        [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]] && break
        sleep 0.5
    done
    if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
        log "endpoint responding: $HEALTH_URL -> HTTP $code"
    else
        log "WARNING: $HEALTH_URL not responding yet; check $LOG_FILE"
    fi
}

stop() {
    local pid i
    pid="$(running_pid || true)"
    if [[ -z "$pid" ]]; then
        rm -f "$PID_FILE"
        log "not running"
        return 0
    fi
    log "stopping server (PID $pid) ..."
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        log "graceful stop timed out after 10s; sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PID_FILE"
    log "server stopped"
}

status() {
    local pid code
    pid="$(running_pid || true)"
    if [[ -n "$pid" ]]; then
        log "running (PID $pid)"
        ps -p "$pid" -o pid,etime,rss,cmd --no-headers 2>/dev/null || true
    else
        log "not running"
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$HEALTH_URL" || true)"
    if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
        if [[ "$code" == "200" ]]; then
            log "endpoint $HEALTH_URL -> HTTP 200 (upstream online)"
        else
            log "endpoint $HEALTH_URL -> HTTP $code (dashboard up, upstream unreachable/stale)"
        fi
    else
        log "endpoint $HEALTH_URL -> no response"
    fi
}

logs() {
    [[ -f "$LOG_FILE" ]] || { log "no log file yet: $LOG_FILE"; return 0; }
    exec tail -n 50 -f "$LOG_FILE"
}

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    status)  status ;;
    logs)    logs ;;
    *)
        echo "Usage: $(basename "$0") {start|stop|restart|status|logs}"
        exit 1
        ;;
esac