#!/usr/bin/env bash
set -euo pipefail

VOLUME_PAIRS="${VOLUME_PAIRS:-}"
SERVICES="${SERVICES:-}"

if [[ -z "$VOLUME_PAIRS" ]]; then
  echo "VOLUME_PAIRS is empty"
  exit 1
fi

IFS=';' read -ra PAIRS <<< "$VOLUME_PAIRS"

volume_is_empty() {
  local vol="$1"
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    return 0
  fi
  docker run --rm -v "$vol:/v" alpine:3.20 sh -lc '[ -z "$(ls -A /v)" ]'
}

sync_volume_from_seed() {
  local seed="$1"
  local live="$2"
  echo ">>> RESET: $live ← $seed"
  docker volume inspect "$seed" >/dev/null 2>&1 || docker volume create "$seed" >/dev/null
  docker volume inspect "$live" >/dev/null 2>&1 || docker volume create "$live" >/dev/null
  docker run --rm -v "$seed:/src:ro" -v "$live:/dst" alpine:3.20 sh -lc 'rm -rf /dst/* && cp -a /src/. /dst/'
}

bake_volume_from_live() {
  local seed="$1"
  local live="$2"
  echo ">>> BAKE: $seed ← $live"
  docker volume inspect "$seed" >/dev/null 2>&1 || docker volume create "$seed" >/dev/null
  docker volume inspect "$live" >/dev/null 2>&1 || docker volume create "$live" >/dev/null
  docker run --rm -v "$live:/src:ro" -v "$seed:/dst" alpine:3.20 sh -lc 'rm -rf /dst/* && cp -a /src/. /dst/'
}

ensure_seed_initialized() {
  local seed="$1"
  local live="$2"
  if volume_is_empty "$seed"; then
    echo ">>> SEED EMPTY: $seed, baking from $live"
    bake_volume_from_live "$seed" "$live"
  fi
}

stop_services() {
  [[ -z "$SERVICES" ]] && return
  echo ">>> stopping: $SERVICES"
  for s in $SERVICES; do docker stop "$s" >/dev/null 2>&1 || true; done
}

start_services() {
  [[ -z "$SERVICES" ]] && return
  echo ">>> starting: $SERVICES"
  for s in $SERVICES; do docker start "$s" >/dev/null 2>&1 || true; done
}

reset_once() {
  echo "=== RESET at $(date -Iseconds) ==="
  stop_services
  for pair in "${PAIRS[@]}"; do
    ensure_seed_initialized "${pair%%:*}" "${pair##*:}"
    sync_volume_from_seed "${pair%%:*}" "${pair##*:}"
  done
  start_services
  echo "=== done ==="
}

bake_once() {
  echo "=== BAKE at $(date -Iseconds) ==="
  stop_services
  for pair in "${PAIRS[@]}"; do bake_volume_from_live "${pair%%:*}" "${pair##*:}"; done
  start_services
  echo "=== done ==="
}

case "${1:-}" in
  reset) reset_once ;;
  bake) bake_once ;;
  "")
    echo "Usage:"
    echo "  bake   # save live → seed"
    echo "  reset  # restore seed → live"
    exit 1
    ;;
  *)
    exec "$@"
    ;;
esac
