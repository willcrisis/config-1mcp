#!/bin/bash
# 1mcp watchdog — restarts the stack if the agent container is unhealthy or stopped.
# Designed to be invoked by launchd every 5 minutes.

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$COMPOSE_DIR/logs/watchdog.log"
MAX_LOG_SIZE=1048576 # 1 MB

mkdir -p "$(dirname "$LOG")"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# Rotate log if too large
if [[ -f "$LOG" ]] && (( $(stat -f%z "$LOG" 2>/dev/null || echo 0) > MAX_LOG_SIZE )); then
  mv "$LOG" "$LOG.1"
fi

# Wait for Docker daemon (up to 5 min at boot, then give up for this cycle)
RETRIES=0
MAX_RETRIES=30
while ! docker info &>/dev/null; do
  RETRIES=$((RETRIES + 1))
  if (( RETRIES > MAX_RETRIES )); then
    log "WARN: Docker daemon not running after ${MAX_RETRIES} attempts, skipping"
    exit 0
  fi
  sleep 10
done

cd "$COMPOSE_DIR"

AGENT_STATUS=$(docker compose ps --format json 2>/dev/null | \
  python3 -c "import sys,json
for line in sys.stdin:
    c=json.loads(line)
    if c.get('Service')=='1mcp':
        print(c.get('State','unknown'))
        break
else:
    print('missing')" 2>/dev/null || echo "error")

if [[ "$AGENT_STATUS" == "running" ]]; then
  # Also check health endpoint directly
  if docker exec 1mcp-agent node -e \
    "fetch('http://localhost:${ONE_MCP_PORT:-3050}/health').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))" \
    &>/dev/null; then
    exit 0
  fi
  log "WARN: Agent container running but health check failed, restarting"
else
  log "WARN: Agent container status: $AGENT_STATUS, restarting"
fi

log "INFO: Restarting 1mcp stack..."
if docker compose up -d 2>>"$LOG"; then
  log "INFO: Restart complete"
else
  log "ERROR: Restart failed (exit $?), will retry next cycle"
fi
