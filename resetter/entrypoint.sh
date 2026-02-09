#!/usr/bin/env bash
set -euo pipefail

VOLUME_PAIRS="${VOLUME_PAIRS:-}"
SERVICES="${SERVICES:-}"
CRON_SCHEDULE="${CRON_SCHEDULE:-}"
CRON_COMMAND="${CRON_COMMAND:-reset}"
LOG_FILE="${LOG_FILE:-/var/log/resetter.log}"

# Setup logging - tee outputs to both file and stdout
log_setup() {
  mkdir -p "$(dirname "$LOG_FILE")"
  # Ensure we write to both stdout and file
  exec > >(tee -a "$LOG_FILE")
  exec 2>&1
}

# Only setup logging if not already done
if [[ "${LOGGING_SETUP:-}" != "1" ]]; then
  export LOGGING_SETUP=1
  log_setup
fi

if [[ -z "$VOLUME_PAIRS" ]]; then
  echo "VOLUME_PAIRS is empty"
  exit 1
fi

IFS=';' read -ra PAIRS <<< "$VOLUME_PAIRS"

# Auto-detect volume prefix from existing volumes
detect_volume_prefix() {
  local sample_vol="${1#*:}"  # Get live volume name from first pair
  # Try both underscore and hyphen versions
  local sample_hyphen="${sample_vol//_/-}"
  echo "[DEBUG] Looking for volume matching: *${sample_vol} or *${sample_hyphen}" >&2
  
  # List all volumes and find matching pattern
  local all_volumes
  all_volumes=$(docker volume ls --format "{{.Name}}")
  
  echo "[DEBUG] Searching in volumes:" >&2
  echo "$all_volumes" | head -10 >&2
  
  # Try to find volume ending with sample_hyphen (e.g., *_postgres-data or *-postgres-data)
  local found
  found=$(echo "$all_volumes" | grep -E "[_-]${sample_hyphen}$" | head -1)
  
  if [[ -z "$found" ]]; then
    # Try with underscore version
    found=$(echo "$all_volumes" | grep -E "[_-]${sample_vol}$" | head -1)
  fi
  
  if [[ -n "$found" ]]; then
    echo "[DEBUG] Found matching volume: $found" >&2
    # Extract prefix - everything before the last separator and volume name
    if [[ "$found" =~ ^(.+)[-_](postgres-data|postgres_data|tmp-data|tmp_data)$ ]]; then
      local prefix="${BASH_REMATCH[1]}"
      local separator="${found:${#prefix}:1}"
      echo "[DEBUG] Detected prefix: '$prefix', separator: '$separator'" >&2
      echo "$prefix|$separator"
    else
      echo "[DEBUG] Could not parse prefix from: $found" >&2
      echo "|_"
    fi
  else
    echo "[DEBUG] No matching volume found, using volumes as-is" >&2
    echo "|_"
  fi
}

# Detect prefix from first pair
VOLUME_PREFIX_INFO=$(detect_volume_prefix "${PAIRS[0]}")
VOLUME_PREFIX="${VOLUME_PREFIX_INFO%|*}"
VOLUME_SEPARATOR="${VOLUME_PREFIX_INFO#*|}"

# Function to get full volume name with prefix
get_volume_name() {
  local vol="$1"
  # Always convert underscores to hyphens in volume names (Coolify uses hyphens)
  local vol_hyphen="${vol//_/-}"
  if [[ -n "$VOLUME_PREFIX" ]]; then
    echo "${VOLUME_PREFIX}_${vol_hyphen}"
  else
    echo "$vol"
  fi
}

write_cron_env() {
  local env_file="/etc/cron.env"
  {
    printf 'VOLUME_PAIRS=%q\n' "$VOLUME_PAIRS"
    printf 'SERVICES=%q\n' "$SERVICES"
  } > "$env_file"
}

start_cron() {
  if [[ -z "$CRON_SCHEDULE" ]]; then
    echo "CRON_SCHEDULE is empty"
    exit 1
  fi
  case "$CRON_COMMAND" in
    reset|bake) ;;
    *)
      echo "CRON_COMMAND must be 'reset' or 'bake'"
      exit 1
      ;;
  esac
  write_cron_env
  mkdir -p /etc/crontabs
  {
    echo "SHELL=/bin/bash"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "LOGGING_SETUP=1"
    # Heartbeat every 5 minutes to confirm cron is alive
    echo "*/5 * * * * echo '[HEARTBEAT] Cron is alive at \$(date -Iseconds)'"
    # Main reset/bake task
    echo "$CRON_SCHEDULE /bin/bash -c 'source /etc/cron.env && /entrypoint.sh $CRON_COMMAND 2>&1'"
  } > /etc/crontabs/root
  
  echo ">>> cron schedule: $CRON_SCHEDULE ($CRON_COMMAND)"
  echo "[DEBUG] Crontab contents:"
  cat /etc/crontabs/root
  echo "[DEBUG] Starting crond with verbose logging..."
  
  # Start crond in foreground with maximum logging
  crond -f -l 0 -L /dev/stdout
}

volume_is_empty() {
  local vol="$1"
  echo "[DEBUG] Checking if volume '$vol' is empty..."
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "[DEBUG]   → Volume does not exist yet, treating as empty"
    return 0
  fi
  local contents
  contents=$(docker run --rm -v "$vol:/v" alpine:3.20 sh -lc 'ls -A /v | head -20')
  echo "[DEBUG]   → Contents: ${contents:-<empty>}"
  docker run --rm -v "$vol:/v" alpine:3.20 sh -lc '[ -z "$(ls -A /v)" ]'
  local result=$?
  echo "[DEBUG]   → Is empty: $result"
  return $result
}

sync_volume_from_seed() {
  local seed="$1"
  local live="$2"
  echo ">>> RESET: $live ← $seed"
  docker volume inspect "$seed" >/dev/null 2>&1 || docker volume create "$seed" >/dev/null
  docker volume inspect "$live" >/dev/null 2>&1 || docker volume create "$live" >/dev/null
  echo "[DEBUG] Before sync:"
  echo "[DEBUG]   seed ($seed): $(docker run --rm -v "$seed:/v" alpine:3.20 sh -lc 'ls -A /v | head -10')"
  echo "[DEBUG]   live ($live): $(docker run --rm -v "$live:/v" alpine:3.20 sh -lc 'ls -A /v | head -10')"
  docker run --rm -v "$seed:/src:ro" -v "$live:/dst" alpine:3.20 sh -lc 'rm -rf /dst/* /dst/.[!.]* /dst/..?* 2>/dev/null || true; cp -a /src/. /dst/'
  echo "[DEBUG] After sync:"
  echo "[DEBUG]   live ($live): $(docker run --rm -v "$live:/v" alpine:3.20 sh -lc 'ls -A /v | head -10')"
}

bake_volume_from_live() {
  local seed="$1"
  local live="$2"
  echo ">>> BAKE: $seed ← $live"
  docker volume inspect "$seed" >/dev/null 2>&1 || docker volume create "$seed" >/dev/null
  docker volume inspect "$live" >/dev/null 2>&1 || docker volume create "$live" >/dev/null
  echo "[DEBUG] Before bake:"
  echo "[DEBUG]   live ($live): $(docker run --rm -v "$live:/v" alpine:3.20 sh -lc 'ls -A /v | head -10')"
  echo "[DEBUG]   seed ($seed): $(docker run --rm -v "$seed:/v" alpine:3.20 sh -lc 'ls -A /v | head -10')"
  docker run --rm -v "$live:/src:ro" -v "$seed:/dst" alpine:3.20 sh -lc 'rm -rf /dst/* /dst/.[!.]* /dst/..?* 2>/dev/null || true; cp -a /src/. /dst/'
  echo "[DEBUG] After bake:"
  echo "[DEBUG]   seed ($seed): $(docker run --rm -v "$seed:/v" alpine:3.20 sh -lc 'ls -A /v | head -10')"
}

ensure_seed_initialized() {
  local seed="$1"
  local live="$2"
  echo "[DEBUG] Ensuring seed '$seed' is initialized..."
  if volume_is_empty "$seed"; then
    echo ">>> SEED EMPTY: $seed, baking from $live"
    bake_volume_from_live "$seed" "$live"
  else
    echo "[DEBUG] Seed '$seed' already has data, skipping initialization"
  fi
}

stop_services() {
  [[ -z "$SERVICES" ]] && return
  echo ">>> stopping: $SERVICES"
  echo "[DEBUG] All running containers:"
  docker ps --format "{{.Names}}"
  for s in $SERVICES; do
    echo "[DEBUG] Trying to stop: $s"
    # Try exact name first, then pattern match
    if docker stop "$s" >/dev/null 2>&1; then
      echo "[DEBUG] Stopped container by exact name: $s"
    else
      # Find container by pattern
      echo "[DEBUG] Container '$s' not found by exact name, searching by pattern..."
      local container
      container=$(docker ps --format "{{.Names}}" | grep -E "${s}" | head -1)
      if [[ -n "$container" ]]; then
        echo "[DEBUG] Found container: $container (matched pattern: ${s})"
        if docker stop "$container" >/dev/null 2>&1; then
          echo "[DEBUG] Successfully stopped: $container"
        else
          echo "[DEBUG] Failed to stop: $container"
        fi
      else
        echo "[DEBUG] No container found matching pattern: ${s}"
      fi
    fi
  done
}

check_and_start_services() {
  [[ -z "$SERVICES" ]] && return
  echo ">>> checking services health: $SERVICES"
  local services_restarted=0
  for s in $SERVICES; do
    local container=""
    # Try to find container by exact name or pattern
    if docker ps -a --format "{{.Names}}" | grep -qE "^${s}$"; then
      container="$s"
    else
      container=$(docker ps -a --format "{{.Names}}" | grep -E "${s}" | head -1)
    fi
    
    if [[ -n "$container" ]]; then
      local status
      status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
      echo "[DEBUG] Container $container status: $status"
      
      if [[ "$status" != "running" ]]; then
        echo "[WARN] Container $container is not running, starting it..."
        if docker start "$container" >/dev/null 2>&1; then
          echo "[INFO] Successfully started: $container"
          services_restarted=$((services_restarted + 1))
        else
          echo "[ERROR] Failed to start: $container"
        fi
      fi
    else
      echo "[DEBUG] Container not found for service: $s"
    fi
  done
  
  if [[ $services_restarted -gt 0 ]]; then
    echo "[INFO] Restarted $services_restarted service(s)"
  else
    echo "[INFO] All services are running"
  fi
}

restart_services() {
  [[ -z "$SERVICES" ]] && return
  echo ">>> starting: $SERVICES"
  echo "[DEBUG] All containers (including stopped):"
  docker ps -a --format "{{.Names}} ({{.Status}})"
  for s in $SERVICES; do
    echo "[DEBUG] Trying to start: $s"
    # Try exact name first, then pattern match
    if docker start "$s" >/dev/null 2>&1; then
      echo "[DEBUG] Started container by exact name: $s"
    else
      # Find container by pattern
      echo "[DEBUG] Container '$s' not found by exact name, searching by pattern..."
      local container
      container=$(docker ps -a --format "{{.Names}}" | grep -E "${s}" | head -1)
      if [[ -n "$container" ]]; then
        echo "[DEBUG] Found container: $container (matched pattern: ${s})"
        if docker start "$container" >/dev/null 2>&1; then
          echo "[DEBUG] Successfully started: $container"
        else
          echo "[DEBUG] Failed to start: $container"
        fi
      else
        echo "[DEBUG] No container found matching pattern: ${s}"
      fi
    fi
  done
  echo "[DEBUG] Final container status:"
  docker ps --format "{{.Names}} ({{.Status}})"
}

reset_once() {
  echo "=== RESET at $(date -Iseconds) ==="
  echo "[INFO] Log file: $LOG_FILE"
  
  # Check and start services if they are down before reset
  check_and_start_services
  
  echo "[DEBUG] VOLUME_PAIRS: $VOLUME_PAIRS"
  echo "[DEBUG] Detected prefix: '${VOLUME_PREFIX:-<none>}'"
  echo "[DEBUG] Parsed pairs:"
  for pair in "${PAIRS[@]}"; do
    local seed=$(get_volume_name "${pair%%:*}")
    local live=$(get_volume_name "${pair##*:}")
    echo "[DEBUG]   - seed: ${pair%%:*} → $seed"
    echo "[DEBUG]   - live: ${pair##*:} → $live"
  done
  echo "[DEBUG] All Docker volumes:"
  docker volume ls --format "{{.Name}}" | head -20
  echo "[DEBUG] ======"
  stop_services
  for pair in "${PAIRS[@]}"; do
    local seed=$(get_volume_name "${pair%%:*}")
    local live=$(get_volume_name "${pair##*:}")
    ensure_seed_initialized "$seed" "$live"
    sync_volume_from_seed "$seed" "$live"
  done
  restart_services
  echo "=== done ==="
}

bake_once() {
  echo "=== BAKE at $(date -Iseconds) ==="
  echo "[INFO] Log file: $LOG_FILE"
  echo "[DEBUG] Detected prefix: '${VOLUME_PREFIX:-<none>}'"
  stop_services
  for pair in "${PAIRS[@]}"; do
    local seed=$(get_volume_name "${pair%%:*}")
    local live=$(get_volume_name "${pair##*:}")
    bake_volume_from_live "$seed" "$live"
  done
  restart_services
  echo "=== done ==="
}

case "${1:-}" in
  reset) reset_once ;;
  bake) bake_once ;;
  cron) start_cron ;;
  "")
    if [[ -n "$CRON_SCHEDULE" ]]; then
      start_cron
    else
      echo "Usage:"
      echo "  bake   # save live → seed"
      echo "  reset  # restore seed → live"
      echo "  cron   # run on CRON_SCHEDULE"
      exit 1
    fi
    ;;
  *)
    exec "$@"
    ;;
esac
