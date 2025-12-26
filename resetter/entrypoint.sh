#!/usr/bin/env bash
set -euo pipefail

VOLUME_PAIRS="${VOLUME_PAIRS:-}"
SERVICES="${SERVICES:-}"
CRON_SCHEDULE="${CRON_SCHEDULE:-}"
CRON_COMMAND="${CRON_COMMAND:-reset}"

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
  
  # Try to find the volume with any prefix (try both _ and - versions)
  local found
  found=$(docker volume ls --format "{{.Name}}" | grep -E "(^|_)(${sample_vol}|${sample_hyphen})$" | head -1)
  
  if [[ -n "$found" ]]; then
    # Extract prefix and actual volume name
    if [[ "$found" =~ ^(.+)[_-](${sample_hyphen})$ ]]; then
      local prefix="${BASH_REMATCH[1]}"
      echo "[DEBUG] Detected volume prefix: '$prefix', using hyphen format" >&2
      echo "$prefix|-"
    elif [[ "$found" =~ ^(.+)_(${sample_vol})$ ]]; then
      local prefix="${BASH_REMATCH[1]}"
      echo "[DEBUG] Detected volume prefix: '$prefix', using underscore format" >&2
      echo "$prefix|_"
    else
      echo "[DEBUG] No prefix detected, using volumes as-is" >&2
      echo "|_"
    fi
  else
    echo "[DEBUG] No prefix detected, using volumes as-is" >&2
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
  # Convert underscores to hyphens if using hyphen separator
  if [[ "$VOLUME_SEPARATOR" == "-" ]]; then
    vol="${vol//_/-}"
  fi
  if [[ -n "$VOLUME_PREFIX" ]]; then
    echo "${VOLUME_PREFIX}${VOLUME_SEPARATOR}${vol}"
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
    echo "$CRON_SCHEDULE /bin/bash -lc 'source /etc/cron.env; /entrypoint.sh $CRON_COMMAND'"
  } > /etc/crontabs/root
  echo ">>> cron schedule: $CRON_SCHEDULE ($CRON_COMMAND)"
  crond -f -l 2
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
  for s in $SERVICES; do
    # Try exact name first, then pattern match
    if ! docker stop "$s" >/dev/null 2>&1; then
      # Find container by pattern
      local container
      container=$(docker ps --format "{{.Names}}" | grep -E "^${s}-" | head -1)
      if [[ -n "$container" ]]; then
        echo "[DEBUG] Found container: $container (matched pattern: ${s}-)" >&2
        docker stop "$container" >/dev/null 2>&1 || true
      fi
    fi
  done
}

restart_services() {
  [[ -z "$SERVICES" ]] && return
  echo ">>> restarting: $SERVICES"
  for s in $SERVICES; do
    # Try exact name first, then pattern match
    if ! docker restart "$s" >/dev/null 2>&1; then
      # Find container by pattern
      local container
      container=$(docker ps -a --format "{{.Names}}" | grep -E "^${s}-" | head -1)
      if [[ -n "$container" ]]; then
        echo "[DEBUG] Found container: $container (matched pattern: ${s}-)" >&2
        docker restart "$container" >/dev/null 2>&1 || true
      fi
    fi
  done
}

reset_once() {
  echo "=== RESET at $(date -Iseconds) ==="
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
