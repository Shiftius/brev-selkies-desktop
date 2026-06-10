#!/usr/bin/env bash
set -euo pipefail

PROGRAM_NAME="$(basename "$0")"
LOG_FILE="${BREV_SELKIES_LOG:-/var/log/brev-selkies-desktop.log}"

SELKIES_IMAGE="${SELKIES_IMAGE:-ghcr.io/selkies-project/nvidia-egl-desktop}"
SELKIES_TAG="${SELKIES_TAG:-}"
SELKIES_CONTAINER_NAME="${SELKIES_CONTAINER_NAME:-brev-selkies-desktop}"
SELKIES_MODE="${SELKIES_MODE:-webrtc}"
SELKIES_ACCELERATION="${SELKIES_ACCELERATION:-auto}"
SELKIES_ENCODER="${SELKIES_ENCODER:-}"
SELKIES_DOCKER_NETWORK="${SELKIES_DOCKER_NETWORK:-auto}"

SELKIES_WEB_PORT="${SELKIES_WEB_PORT:-8080}"
SELKIES_TURN_PORT="${SELKIES_TURN_PORT:-47998}"
SELKIES_TURN_MIN_PORT="${SELKIES_TURN_MIN_PORT:-47999}"
SELKIES_TURN_MAX_PORT="${SELKIES_TURN_MAX_PORT:-48015}"
SELKIES_MIN_RELAY_PORT_COUNT="${SELKIES_MIN_RELAY_PORT_COUNT:-8}"
SELKIES_TURN_PROTOCOL="${SELKIES_TURN_PROTOCOL:-udp}"
SELKIES_TURN_ENABLE_TCP="${SELKIES_TURN_ENABLE_TCP:-0}"
SELKIES_TURN_HOST="${SELKIES_TURN_HOST:-}"
SELKIES_TURN_EXTERNAL_IP="${SELKIES_TURN_EXTERNAL_IP:-${TURN_EXTERNAL_IP:-}}"
SELKIES_AUTO_TURN_HOST="${SELKIES_AUTO_TURN_HOST:-1}"

SELKIES_ENABLE_BASIC_AUTH="${SELKIES_ENABLE_BASIC_AUTH:-false}"
SELKIES_BASIC_AUTH_USER="${SELKIES_BASIC_AUTH_USER:-ubuntu}"
REMOTE_DESKTOP_PASSWORD="${REMOTE_DESKTOP_PASSWORD:-}"

SELKIES_DISPLAY_WIDTH="${SELKIES_DISPLAY_WIDTH:-1920}"
SELKIES_DISPLAY_HEIGHT="${SELKIES_DISPLAY_HEIGHT:-1080}"
SELKIES_DISPLAY_REFRESH="${SELKIES_DISPLAY_REFRESH:-60}"
SELKIES_VIDEO_BITRATE="${SELKIES_VIDEO_BITRATE:-8000}"
SELKIES_FRAMERATE="${SELKIES_FRAMERATE:-60}"
SELKIES_AUDIO_BITRATE="${SELKIES_AUDIO_BITRATE:-128000}"

FIREWALL_CONFIGURE="${FIREWALL_CONFIGURE:-auto}"
PUBLIC_IP_URLS="${PUBLIC_IP_URLS:-https://icanhazip.com https://api.ipify.org https://ifconfig.me/ip}"
HEALTHCHECK_ATTEMPTS="${HEALTHCHECK_ATTEMPTS:-24}"
HEALTHCHECK_INTERVAL_SECONDS="${HEALTHCHECK_INTERVAL_SECONDS:-5}"

APT_UPDATED=0

usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} [--help|--print-config]

Install a Selkies browser desktop on Brev.

Core settings:
  SELKIES_ACCELERATION=auto|hardware|software
    auto chooses hardware when a healthy NVIDIA GPU and NVIDIA container runtime
    are available; otherwise software.
    hardware uses nvh264enc and Docker --gpus all.
    software uses x264enc and does not request Docker GPU access.
  SELKIES_MODE=webrtc|kasmvnc
    webrtc uses 8080/tcp plus TURN ports.
    kasmvnc uses only 8080/tcp and is the last-resort single-port mode.
  SELKIES_ENCODER=<gstreamer encoder>
    Optional override, for example nvh264enc, x264enc, vp8enc, or vp9enc.

Default Brev ports:
  8080/tcp
  47998/udp
  47999-48015/udp
EOF
}

log() {
  local message="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
  echo "$message"
  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    { echo "$message" >> "$LOG_FILE"; } 2>/dev/null || true
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "Run as root, for example: curl -fsSL URL | sudo -E bash"
}

ubuntu_version() {
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Unsupported OS: ${ID:-unknown}; Ubuntu 22.04 or 24.04 is required"
  case "${VERSION_ID:-}" in
    22.04|24.04) printf '%s\n' "$VERSION_ID" ;;
    *) die "Unsupported Ubuntu version: ${VERSION_ID:-unknown}; expected 22.04 or 24.04" ;;
  esac
}

validate_config() {
  case "$SELKIES_MODE" in
    webrtc|kasmvnc) ;;
    *) die "SELKIES_MODE must be webrtc or kasmvnc; got '${SELKIES_MODE}'" ;;
  esac
  case "$SELKIES_ACCELERATION" in
    auto|hardware|software) ;;
    *) die "SELKIES_ACCELERATION must be auto, hardware, or software; got '${SELKIES_ACCELERATION}'" ;;
  esac
  case "$SELKIES_DOCKER_NETWORK" in
    auto|bridge|host) ;;
    *) die "SELKIES_DOCKER_NETWORK must be auto, bridge, or host; got '${SELKIES_DOCKER_NETWORK}'" ;;
  esac
  case "$SELKIES_TURN_PROTOCOL" in
    udp|tcp) ;;
    *) die "SELKIES_TURN_PROTOCOL must be udp or tcp; got '${SELKIES_TURN_PROTOCOL}'" ;;
  esac
  [[ "$SELKIES_TURN_MIN_PORT" =~ ^[0-9]+$ ]] || die "SELKIES_TURN_MIN_PORT must be numeric"
  [[ "$SELKIES_TURN_MAX_PORT" =~ ^[0-9]+$ ]] || die "SELKIES_TURN_MAX_PORT must be numeric"
  [[ "$SELKIES_MIN_RELAY_PORT_COUNT" =~ ^[0-9]+$ ]] || die "SELKIES_MIN_RELAY_PORT_COUNT must be numeric"
  if (( SELKIES_TURN_MAX_PORT < SELKIES_TURN_MIN_PORT )); then
    die "SELKIES_TURN_MAX_PORT must be greater than or equal to SELKIES_TURN_MIN_PORT"
  fi
  if [[ "$SELKIES_MODE" == "webrtc" ]] && (( SELKIES_TURN_MAX_PORT - SELKIES_TURN_MIN_PORT + 1 < SELKIES_MIN_RELAY_PORT_COUNT )); then
    die "Selkies WebRTC needs at least ${SELKIES_MIN_RELAY_PORT_COUNT} TURN relay ports; got ${SELKIES_TURN_MIN_PORT}-${SELKIES_TURN_MAX_PORT}. Increase SELKIES_TURN_MAX_PORT or lower SELKIES_MIN_RELAY_PORT_COUNT only for single-user testing."
  fi
}

apt_install() {
  if [[ "$APT_UPDATED" == "0" ]]; then
    log "Running: apt-get update"
    apt-get update
    APT_UPDATED=1
  fi
  log "Running: apt-get install -y --no-install-recommends $*"
  apt-get install -y --no-install-recommends "$@"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    apt_install ca-certificates curl docker.io
  fi
  if command -v systemctl >/dev/null 2>&1; then
    log "Running: systemctl enable --now docker"
    systemctl enable --now docker
  fi
}

nvidia_runtime_ready() {
  command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi -L >/dev/null 2>&1 \
    && command -v nvidia-container-cli >/dev/null 2>&1 \
    && nvidia-container-cli info >/dev/null 2>&1
}

resolve_acceleration() {
  case "$SELKIES_ACCELERATION" in
    hardware)
      nvidia_runtime_ready || die "SELKIES_ACCELERATION=hardware requires a healthy NVIDIA GPU and NVIDIA container runtime"
      printf '%s\n' hardware
      ;;
    software)
      printf '%s\n' software
      ;;
    auto)
      if nvidia_runtime_ready; then
        printf '%s\n' hardware
      else
        printf '%s\n' software
      fi
      ;;
  esac
}

resolve_encoder() {
  local acceleration="$1"
  if [[ -n "$SELKIES_ENCODER" ]]; then
    printf '%s\n' "$SELKIES_ENCODER"
    return 0
  fi
  case "$acceleration" in
    hardware) printf '%s\n' nvh264enc ;;
    software) printf '%s\n' x264enc ;;
  esac
}

resolve_network() {
  if [[ "$SELKIES_DOCKER_NETWORK" == "auto" ]]; then
    printf '%s\n' bridge
  else
    printf '%s\n' "$SELKIES_DOCKER_NETWORK"
  fi
}

detect_public_ipv4() {
  local url ip
  for url in $PUBLIC_IP_URLS; do
    if ip="$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" \
      && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

resolve_turn_host() {
  if [[ "$SELKIES_MODE" != "webrtc" ]]; then
    return 0
  fi
  if [[ -n "$SELKIES_TURN_HOST" ]]; then
    SELKIES_TURN_EXTERNAL_IP="${SELKIES_TURN_EXTERNAL_IP:-$SELKIES_TURN_HOST}"
    return 0
  fi
  if is_truthy "$SELKIES_AUTO_TURN_HOST"; then
    SELKIES_TURN_HOST="$(detect_public_ipv4 || true)"
    SELKIES_TURN_EXTERNAL_IP="${SELKIES_TURN_EXTERNAL_IP:-$SELKIES_TURN_HOST}"
  fi
}

configure_ufw() {
  command -v ufw >/dev/null 2>&1 || return 0
  if [[ "$FIREWALL_CONFIGURE" == "never" ]]; then
    return 0
  fi
  if [[ "$FIREWALL_CONFIGURE" == "auto" ]] && ! ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "Skipping UFW configuration because ufw is inactive"
    return 0
  fi

  log "Opening UFW ${SELKIES_WEB_PORT}/tcp"
  ufw allow "${SELKIES_WEB_PORT}/tcp" >/dev/null || true
  if [[ "$SELKIES_MODE" == "webrtc" ]]; then
    if [[ "$SELKIES_TURN_PROTOCOL" != "tcp" ]]; then
      ufw allow "${SELKIES_TURN_PORT}/udp" >/dev/null || true
      ufw allow "${SELKIES_TURN_MIN_PORT}:${SELKIES_TURN_MAX_PORT}/udp" >/dev/null || true
    fi
    if is_truthy "$SELKIES_TURN_ENABLE_TCP" || [[ "$SELKIES_TURN_PROTOCOL" == "tcp" ]]; then
      ufw allow "${SELKIES_TURN_PORT}/tcp" >/dev/null || true
      ufw allow "${SELKIES_TURN_MIN_PORT}:${SELKIES_TURN_MAX_PORT}/tcp" >/dev/null || true
    fi
  fi
}

require_tcp_port_free() {
  local port="$1"
  if ss -ltn "( sport = :$port )" 2>/dev/null | awk 'NR > 1 { found=1 } END { exit(found ? 0 : 1) }'; then
    die "TCP port ${port} is already listening"
  fi
}

docker_port_args() {
  local network="$1"
  [[ "$network" == "host" ]] && return 0

  printf -- '-p %s:8080 ' "$SELKIES_WEB_PORT"
  [[ "$SELKIES_MODE" == "kasmvnc" ]] && return 0

  if is_truthy "$SELKIES_TURN_ENABLE_TCP" || [[ "$SELKIES_TURN_PROTOCOL" == "tcp" ]]; then
    printf -- '-p %s:%s ' "$SELKIES_TURN_PORT" "$SELKIES_TURN_PORT"
    printf -- '-p %s-%s:%s-%s ' "$SELKIES_TURN_MIN_PORT" "$SELKIES_TURN_MAX_PORT" "$SELKIES_TURN_MIN_PORT" "$SELKIES_TURN_MAX_PORT"
  fi
  if [[ "$SELKIES_TURN_PROTOCOL" != "tcp" ]]; then
    printf -- '-p %s:%s/udp ' "$SELKIES_TURN_PORT" "$SELKIES_TURN_PORT"
    printf -- '-p %s-%s:%s-%s/udp ' "$SELKIES_TURN_MIN_PORT" "$SELKIES_TURN_MAX_PORT" "$SELKIES_TURN_MIN_PORT" "$SELKIES_TURN_MAX_PORT"
  fi
}

healthcheck() {
  local attempt
  for attempt in $(seq 1 "$HEALTHCHECK_ATTEMPTS"); do
    if curl -fsS "http://127.0.0.1:${SELKIES_WEB_PORT}/" >/dev/null 2>&1; then
      log "Healthcheck passed on http://127.0.0.1:${SELKIES_WEB_PORT}/"
      return 0
    fi
    log "Healthcheck attempt ${attempt}/${HEALTHCHECK_ATTEMPTS} did not pass yet"
    sleep "$HEALTHCHECK_INTERVAL_SECONDS"
  done
  die "Healthcheck failed on http://127.0.0.1:${SELKIES_WEB_PORT}/"
}

print_config() {
  local tag="${SELKIES_TAG:-auto}"
  if [[ -z "$SELKIES_TAG" && -r /etc/os-release ]]; then
    tag="$(ubuntu_version)"
  fi
  cat <<EOF
SELKIES_IMAGE=${SELKIES_IMAGE}
SELKIES_TAG=${tag}
SELKIES_MODE=${SELKIES_MODE}
SELKIES_ACCELERATION=${SELKIES_ACCELERATION}
SELKIES_DOCKER_NETWORK=${SELKIES_DOCKER_NETWORK}
SELKIES_WEB_PORT=${SELKIES_WEB_PORT}
SELKIES_TURN_PORT=${SELKIES_TURN_PORT}
SELKIES_TURN_MIN_PORT=${SELKIES_TURN_MIN_PORT}
SELKIES_TURN_MAX_PORT=${SELKIES_TURN_MAX_PORT}
SELKIES_MIN_RELAY_PORT_COUNT=${SELKIES_MIN_RELAY_PORT_COUNT}
EOF
}

main() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
    --print-config)
      validate_config
      print_config
      exit 0
      ;;
    "")
      ;;
    *)
      usage
      exit 2
      ;;
  esac

  require_root
  validate_config
  apt_install ca-certificates curl
  ensure_docker

  local version image_ref acceleration encoder network
  version="${SELKIES_TAG:-$(ubuntu_version)}"
  image_ref="${SELKIES_IMAGE}:${version}"
  acceleration="$(resolve_acceleration)"
  encoder="$(resolve_encoder "$acceleration")"
  network="$(resolve_network)"

  log "Installing Selkies desktop from ${image_ref}"
  log "Mode: ${SELKIES_MODE}; acceleration: ${acceleration}; encoder: ${encoder}; network: ${network}"

  resolve_turn_host
  configure_ufw
  require_tcp_port_free "$SELKIES_WEB_PORT"
  if [[ "$SELKIES_MODE" == "webrtc" ]] && { is_truthy "$SELKIES_TURN_ENABLE_TCP" || [[ "$SELKIES_TURN_PROTOCOL" == "tcp" ]]; }; then
    require_tcp_port_free "$SELKIES_TURN_PORT"
  fi

  docker rm -f "$SELKIES_CONTAINER_NAME" >/dev/null 2>&1 || true

  local network_args=()
  if [[ "$network" == "host" ]]; then
    network_args=( --network host )
  fi

  # shellcheck disable=SC2206
  local port_args=( $(docker_port_args "$network") )
  local gpu_args=()
  local env_args=(
    -e "TZ=${TZ:-UTC}"
    -e "DISPLAY_SIZEW=${SELKIES_DISPLAY_WIDTH}"
    -e "DISPLAY_SIZEH=${SELKIES_DISPLAY_HEIGHT}"
    -e "DISPLAY_REFRESH=${SELKIES_DISPLAY_REFRESH}"
    -e "DISPLAY_DPI=96"
    -e "DISPLAY_CDEPTH=24"
    -e "SELKIES_ENABLE_BASIC_AUTH=${SELKIES_ENABLE_BASIC_AUTH}"
    -e "SELKIES_BASIC_AUTH_USER=${SELKIES_BASIC_AUTH_USER}"
    -e "KASMVNC_ENABLE=$([[ "$SELKIES_MODE" == "kasmvnc" ]] && printf true || printf false)"
    -e "SELKIES_ENCODER=${encoder}"
    -e "SELKIES_VIDEO_BITRATE=${SELKIES_VIDEO_BITRATE}"
    -e "SELKIES_FRAMERATE=${SELKIES_FRAMERATE}"
    -e "SELKIES_AUDIO_BITRATE=${SELKIES_AUDIO_BITRATE}"
    -e "SELKIES_TURN_PROTOCOL=${SELKIES_TURN_PROTOCOL}"
    -e "SELKIES_TURN_PORT=${SELKIES_TURN_PORT}"
    -e "TURN_MIN_PORT=${SELKIES_TURN_MIN_PORT}"
    -e "TURN_MAX_PORT=${SELKIES_TURN_MAX_PORT}"
  )

  if [[ -n "$SELKIES_TURN_HOST" ]]; then
    env_args+=( -e "SELKIES_TURN_HOST=${SELKIES_TURN_HOST}" )
  fi
  if [[ -n "$SELKIES_TURN_EXTERNAL_IP" ]]; then
    env_args+=( -e "TURN_EXTERNAL_IP=${SELKIES_TURN_EXTERNAL_IP}" )
  fi

  if is_truthy "$SELKIES_ENABLE_BASIC_AUTH"; then
    [[ -n "$REMOTE_DESKTOP_PASSWORD" ]] || die "REMOTE_DESKTOP_PASSWORD is required when SELKIES_ENABLE_BASIC_AUTH=true"
    env_args+=(
      -e "PASSWD=${REMOTE_DESKTOP_PASSWORD}"
      -e "SELKIES_BASIC_AUTH_PASSWORD=${REMOTE_DESKTOP_PASSWORD}"
    )
  fi

  if [[ "$acceleration" == "hardware" ]]; then
    gpu_args=( --gpus all )
    env_args+=(
      -e "NVIDIA_VISIBLE_DEVICES=all"
      -e "NVIDIA_DRIVER_CAPABILITIES=all"
    )
  fi

  log "Running: docker pull ${image_ref}"
  docker pull "$image_ref"
  log "Starting container ${SELKIES_CONTAINER_NAME}"
  docker run -d \
    --name "$SELKIES_CONTAINER_NAME" \
    --restart unless-stopped \
    "${gpu_args[@]}" \
    "${network_args[@]}" \
    --tmpfs /dev/shm:rw \
    "${env_args[@]}" \
    "${port_args[@]}" \
    "$image_ref"

  healthcheck
  log "Selkies desktop is ready. Expose ${SELKIES_WEB_PORT}/tcp as the Brev Secure Link."
  if [[ "$SELKIES_MODE" == "webrtc" ]]; then
    log "Also expose ${SELKIES_TURN_PORT}/udp and ${SELKIES_TURN_MIN_PORT}-${SELKIES_TURN_MAX_PORT}/udp for WebRTC TURN."
  fi
}

main "$@"
