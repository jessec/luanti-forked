#!/usr/bin/env bash
set -euo pipefail

# ===== Config (override via env or flags) =====
IMAGE="${IMAGE:-luanti-server:local}"
CONTAINER="${CONTAINER:-luanti}"
WORLD_NAME="${WORLD_NAME:-eduquest}"
PORT="${PORT:-30000}"               # both TCP+UDP
GAMES_VOL="${GAMES_VOL:-luanti-games}"
DATA_VOL="${DATA_VOL:-luanti-data}"
CONFIG_VOL="${CONFIG_VOL:-luanti-config}"
GAME_ID="${GAME_ID:-mineclonia}"
GAME_DL_URL="${GAME_DL_URL:-https://content.eduquest.vip/packages/rubenwardy/mineclonia/download}"

# ===== Helpers =====
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
exists_container(){ docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; }
running_container(){ docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; }

usage(){
cat <<EOF
Usage: $0 <command> [--image X] [--port N] [--world NAME] [--container NAME]

Commands:
  bootstrap     Create volumes, download Mineclonia into ${GAMES_VOL}, copy to user-path, ensure world+config.
  up            Run (or re-run) the server container with gameid=${GAME_ID}.
  restart       Restart container (create if missing).
  down          Stop & remove the container (volumes are preserved).
  update-game   Re-download Mineclonia and copy to user-path (keeps world data).
  logs          Tail container logs.
  status        Show container status and mapped ports.
  purge         Remove container AND all volumes (DANGEROUS).

Flags/Env:
  IMAGE, CONTAINER, PORT, WORLD_NAME, GAMES_VOL, DATA_VOL, CONFIG_VOL, GAME_DL_URL

Examples:
  $0 bootstrap
  $0 up
  PORT=31000 $0 up
EOF
}

# ===== Steps =====
ensure_volumes(){
  info "Ensuring volumes: ${GAMES_VOL}, ${DATA_VOL}, ${CONFIG_VOL}"
  docker volume create "${GAMES_VOL}" >/dev/null
  docker volume create "${DATA_VOL}"  >/dev/null
  docker volume create "${CONFIG_VOL}" >/dev/null
}

download_game_into_games_vol(){
  info "Downloading ${GAME_ID} into volume ${GAMES_VOL}"
  docker run --rm -v "${GAMES_VOL}:/usr/share/minetest/games" alpine:3.20 sh -lc "
    set -e
    apk add --no-cache curl unzip >/dev/null
    cd /usr/share/minetest/games
    curl -fL -o ${GAME_ID}.zip '${GAME_DL_URL}'
    unzip -q ${GAME_ID}.zip
    rm -f ${GAME_ID}.zip
    [ -d ${GAME_ID} ] || mv ${GAME_ID}-* ${GAME_ID}
    test -f ${GAME_ID}/game.conf
  " >/dev/null
  info "Game downloaded to games volume"
}

copy_game_to_userpath(){
  info "Copying ${GAME_ID} into user path inside ${DATA_VOL} (/var/lib/minetest/.minetest/games)"
  docker run --rm -v "${GAMES_VOL}:/g" -v "${DATA_VOL}:/data" alpine:3.20 sh -lc "
    set -e
    mkdir -p /data/.minetest/games
    rm -rf /data/.minetest/games/${GAME_ID}
    cp -a /g/${GAME_ID} /data/.minetest/games/
    test -f /data/.minetest/games/${GAME_ID}/game.conf
  " >/dev/null
  info "Game staged at user-path ✅"
}

ensure_world_and_config(){
  info "Ensuring world directory and default minetest.conf"
  docker run --rm -v "${DATA_VOL}:/data" -v "${CONFIG_VOL}:/config" alpine:3.20 sh -lc "
    set -e
    mkdir -p /data/worlds/${WORLD_NAME}
    mkdir -p /config
    [ -f /config/minetest.conf ] || cat > /config/minetest.conf <<'CFG'
# Minimal default config (extend as needed)
# enable_ipv6 = true
# max_users = 60
CFG
  " >/dev/null
}

run_container(){
  if exists_container; then
    if running_container; then
      info "Container ${CONTAINER} is already running. Restarting to pick up changes..."
      docker restart "${CONTAINER}" >/dev/null
      return
    else
      info "Removing stopped container ${CONTAINER}"
      docker rm -f "${CONTAINER}" >/dev/null || true
    fi
  fi

  info "Starting ${CONTAINER} on TCP/UDP ${PORT} with world ${WORLD_NAME} and gameid=${GAME_ID}"
  docker run -d --name "${CONTAINER}" \
    -p "${PORT}:${PORT}/udp" -p "${PORT}:${PORT}" \
    -v "${DATA_VOL}:/var/lib/minetest" \
    -v "${CONFIG_VOL}:/etc/minetest" \
    "${IMAGE}" \
      --world "/var/lib/minetest/worlds/${WORLD_NAME}" \
      --gameid "${GAME_ID}" \
      --config "/etc/minetest/minetest.conf" \
      --port "${PORT}" >/dev/null

  info "Container started. Tail logs with: $0 logs"
}

cmd_bootstrap(){
  ensure_volumes
  download_game_into_games_vol
  copy_game_to_userpath
  ensure_world_and_config
  run_container
}

cmd_up(){
  ensure_volumes
  # Only stage game if missing
  if ! docker run --rm -v "${DATA_VOL}:/data" alpine:3.20 sh -lc "test -f /data/.minetest/games/${GAME_ID}/game.conf"; then
    warn "Game not found at user-path; staging now…"
    download_game_into_games_vol
    copy_game_to_userpath
  fi
  ensure_world_and_config
  run_container
}

cmd_restart(){
  if ! exists_container; then
    warn "Container not found; running 'up' instead."
    cmd_up
  else
    info "Restarting ${CONTAINER}"
    docker restart "${CONTAINER}" >/dev/null
    $0 status || true
  fi
}

cmd_down(){
  if exists_container; then
    info "Stopping & removing ${CONTAINER}"
    docker rm -f "${CONTAINER}" >/dev/null || true
  else
    warn "Container ${CONTAINER} not found."
  fi
}

cmd_update_game(){
  ensure_volumes
  download_game_into_games_vol
  copy_game_to_userpath
  if exists_container; then
    info "Game updated; restarting container to load new game."
    docker restart "${CONTAINER}" >/dev/null || true
  fi
  info "Update complete."
}

cmd_logs(){ docker logs -f "${CONTAINER}"; }
cmd_status(){
  docker ps -a --filter "name=${CONTAINER}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}"
}
cmd_purge(){
  warn "This will remove container AND ALL VOLUMES: ${DATA_VOL}, ${CONFIG_VOL}, ${GAMES_VOL}"
  read -rp "Type 'PURGE' to continue: " x
  if [[ "${x:-}" == "PURGE" ]]; then
    docker rm -f "${CONTAINER}" 2>/dev/null || true
    docker volume rm "${DATA_VOL}" "${CONFIG_VOL}" "${GAMES_VOL}"
    info "Purged."
  else
    warn "Aborted."
  fi
}

# ===== Dispatch =====
CMD="${1:-}"; shift || true
case "${CMD}" in
  bootstrap) cmd_bootstrap ;;
  up)        cmd_up ;;
  restart)   cmd_restart ;;
  down)      cmd_down ;;
  update-game) cmd_update_game ;;
  logs)      cmd_logs ;;
  status)    cmd_status ;;
  purge)     cmd_purge ;;
  -h|--help|"") usage ;;
  *)
    err "Unknown command: ${CMD}"
    usage
    exit 1
    ;;
esac

