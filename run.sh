#!/usr/bin/env bash
# Start google-ads-mcp with GOOGLE_ADS_* env from google-ads.yaml.
#
# Usage:
#   ./run.sh                  foreground (stdio MCP / default)
#   ./run.sh fg               same as above
#   ./run.sh start            daemon (nohup + PID file + log)
#   ./run.sh stop
#   ./run.sh restart
#   ./run.sh status
#
# Override paths:
#   RUN_MCP_PIDFILE  default: <repo>/run-mcp.pid
#   RUN_MCP_LOG      default: <repo>/run-mcp.log
#   GOOGLE_ADS_YAML  default: <repo>/google-ads.yaml
#
# Prerequisite: Application Default Credentials with adwords scope, e.g.
#   gcloud auth application-default login \
#     --scopes https://www.googleapis.com/auth/adwords,https://www.googleapis.com/auth/cloud-platform \
#     --client-id-file=YOUR_OAUTH_CLIENT_JSON
# Optional: export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa.json before running.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML="${GOOGLE_ADS_YAML:-$ROOT/google-ads.yaml}"
PIDFILE="${RUN_MCP_PIDFILE:-$ROOT/run-mcp.pid}"
LOGFILE="${RUN_MCP_LOG:-$ROOT/run-mcp.log}"

if [[ ! -f "$YAML" ]]; then
  echo "run.sh: missing config file: $YAML" >&2
  echo "Set GOOGLE_ADS_YAML to your google-ads.yaml path, or place it next to this script." >&2
  exit 1
fi

eval "$(python3 - "$YAML" <<'PY'
import sys
import shlex
from pathlib import Path


def load_simple(p: Path) -> dict:
    """Flat key: value lines only (enough for google-ads.yaml)."""
    out = {}
    for line in p.read_text(encoding="utf-8").splitlines():
        s = line.split("#", 1)[0].strip()
        if not s or ":" not in s:
            continue
        k, _, rest = s.partition(":")
        k = k.strip()
        v = rest.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if k and v:
            out[k] = v
    return out


p = Path(sys.argv[1])
cfg = load_simple(p)
dt = (cfg.get("developer_token") or "").strip()
if not dt:
    sys.exit("developer_token missing or empty in " + str(p))
print(f"export GOOGLE_ADS_DEVELOPER_TOKEN={shlex.quote(dt)}")
lcid = (cfg.get("login_customer_id") or "").strip().replace("-", "")
if lcid:
    print(f"export GOOGLE_ADS_LOGIN_CUSTOMER_ID={shlex.quote(lcid)}")
PY
)"

mcp_server_cmd() {
  cd "$ROOT"
  if command -v uv >/dev/null 2>&1; then
    exec uv run python -m ads_mcp.server "$@"
  else
    export PYTHONPATH="${ROOT}${PYTHONPATH:+:$PYTHONPATH}"
    exec python3 -m ads_mcp.server "$@"
  fi
}

is_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "${pid:-}" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

cmd_start() {
  if is_running; then
    echo "run.sh: already running (pid $(cat "$PIDFILE"))" >&2
    exit 1
  fi
  rm -f "$PIDFILE"
  cd "$ROOT"
  if command -v uv >/dev/null 2>&1; then
    nohup uv run python -m ads_mcp.server "$@" >>"$LOGFILE" 2>&1 &
  else
    export PYTHONPATH="${ROOT}${PYTHONPATH:+:$PYTHONPATH}"
    nohup python3 -m ads_mcp.server "$@" >>"$LOGFILE" 2>&1 &
  fi
  echo $! >"$PIDFILE"
  sleep 0.3
  if is_running; then
    echo "run.sh: started pid $(cat "$PIDFILE"), log $LOGFILE"
  else
    echo "run.sh: start failed; see $LOGFILE" >&2
    rm -f "$PIDFILE"
    exit 1
  fi
}

cmd_stop() {
  if [[ ! -f "$PIDFILE" ]]; then
    echo "run.sh: not running (no pid file)"
    return 0
  fi
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -z "${pid:-}" ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PIDFILE"
    echo "run.sh: not running (removed stale pid file)"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local i=0
  while kill -0 "$pid" 2>/dev/null && [[ $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  echo "run.sh: stopped"
}

cmd_status() {
  if is_running; then
    echo "run.sh: running (pid $(cat "$PIDFILE"), log $LOGFILE)"
    return 0
  fi
  [[ -f "$PIDFILE" ]] && rm -f "$PIDFILE"
  echo "run.sh: stopped"
  return 1
}

cmd_restart() {
  cmd_stop || true
  cmd_start "$@"
}

if [[ $# -eq 0 ]]; then
  mcp_server_cmd
fi

case "$1" in
  start)
    shift
    cmd_start "$@"
    ;;
  stop)
    cmd_stop
    ;;
  restart)
    shift
    cmd_restart "$@"
    ;;
  status)
    cmd_status
    ;;
  fg | foreground)
    shift
    mcp_server_cmd "$@"
    ;;
  -h | --help | help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    mcp_server_cmd "$@"
    ;;
esac
