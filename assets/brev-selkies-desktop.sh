#!/usr/bin/env bash
set -euo pipefail

PROGRAM_NAME="$(basename "$0")"
LOG_FILE="${BREV_SELKIES_LOG:-/var/log/brev-selkies-desktop.log}"

SELKIES_IMAGE="${SELKIES_IMAGE:-}"
SELKIES_HARDWARE_IMAGE="${SELKIES_HARDWARE_IMAGE:-ghcr.io/selkies-project/nvidia-glx-desktop}"
SELKIES_SOFTWARE_IMAGE="${SELKIES_SOFTWARE_IMAGE:-ghcr.io/selkies-project/nvidia-egl-desktop}"
SELKIES_TAG="${SELKIES_TAG:-}"
SELKIES_CONTAINER_NAME="${SELKIES_CONTAINER_NAME:-brev-selkies-desktop}"
SELKIES_DEPLOYMENT="${SELKIES_DEPLOYMENT:-container}"
SELKIES_HOST_DOCKER="${SELKIES_HOST_DOCKER:-1}"
SELKIES_MODE="${SELKIES_MODE:-webrtc}"
SELKIES_ACCELERATION="${SELKIES_ACCELERATION:-auto}"
SELKIES_ENCODER="${SELKIES_ENCODER:-}"
SELKIES_DOCKER_NETWORK="${SELKIES_DOCKER_NETWORK:-auto}"
SELKIES_NATIVE_USER="${SELKIES_NATIVE_USER:-ubuntu}"
SELKIES_NATIVE_DISPLAY="${SELKIES_NATIVE_DISPLAY:-:99}"
SELKIES_NATIVE_DIR="${SELKIES_NATIVE_DIR:-/opt/selkies-gstreamer}"
SELKIES_NATIVE_VERSION="${SELKIES_NATIVE_VERSION:-}"
SELKIES_NATIVE_X_SERVER="${SELKIES_NATIVE_X_SERVER:-auto}"
SELKIES_TURN_REALM="${SELKIES_TURN_REALM:-brev-selkies-desktop}"
SELKIES_TURN_USERNAME="${SELKIES_TURN_USERNAME:-selkies}"
SELKIES_TURN_PASSWORD="${SELKIES_TURN_PASSWORD:-}"

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
  SELKIES_DEPLOYMENT=container|native
    container runs the Selkies desktop image. native installs host Selkies,
    coturn, and a host XFCE desktop with systemd services.
  SELKIES_HOST_DOCKER=1|0
    Container deployment only. When enabled, mount the host Docker socket into
    the desktop so Docker commands from the desktop control the Brev host.
  SELKIES_NATIVE_VERSION=<selkies release>
    Native deployment only. Defaults to the latest selkies-project/selkies
    GitHub release, for example 1.6.2.
  SELKIES_NATIVE_X_SERVER=auto|nvidia|xvfb
    Native deployment only. auto uses NVIDIA Xorg for hardware mode and Xvfb
    for software mode.
  SELKIES_MODE=webrtc|kasmvnc
    webrtc uses 8080/tcp plus TURN ports.
    kasmvnc uses only 8080/tcp and is the last-resort single-port mode.
  SELKIES_ENCODER=<gstreamer encoder>
    Optional override, for example nvh264enc, x264enc, vp8enc, or vp9enc.
  SELKIES_IMAGE=<image>
    Optional override. When unset, hardware mode uses SELKIES_HARDWARE_IMAGE
    and software mode uses SELKIES_SOFTWARE_IMAGE.

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
  case "$SELKIES_DEPLOYMENT" in
    container|native) ;;
    *) die "SELKIES_DEPLOYMENT must be container or native; got '${SELKIES_DEPLOYMENT}'" ;;
  esac
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
  case "$SELKIES_NATIVE_X_SERVER" in
    auto|nvidia|xvfb) ;;
    *) die "SELKIES_NATIVE_X_SERVER must be auto, nvidia, or xvfb; got '${SELKIES_NATIVE_X_SERVER}'" ;;
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

install_firefox_deb() {
  log "Installing Firefox from Mozilla's apt repository"
  apt_install ca-certificates curl gnupg

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
    -o /etc/apt/keyrings/packages.mozilla.org.asc
  cat > /etc/apt/sources.list.d/mozilla.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
EOF
  cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

  log "Running: apt-get update"
  apt-get update
  APT_UPDATED=1
  log "Running: apt-get install -y --allow-downgrades --no-install-recommends firefox"
  apt-get install -y --allow-downgrades --no-install-recommends firefox

  if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
    log "Removing Firefox snap now that Mozilla Firefox deb is installed"
    snap remove firefox >/dev/null 2>&1 || true
  fi
  if command -v update-alternatives >/dev/null 2>&1 && command -v firefox >/dev/null 2>&1; then
    update-alternatives --install /usr/bin/x-www-browser x-www-browser "$(command -v firefox)" 200 >/dev/null 2>&1 || true
    update-alternatives --set x-www-browser "$(command -v firefox)" >/dev/null 2>&1 || true
  fi
  log "Firefox available at: $(command -v firefox)"
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

ensure_docker_for_desktop() {
  ensure_docker
  command -v docker >/dev/null 2>&1 || die "Docker CLI is required for SELKIES_HOST_DOCKER=1"
  [[ -S /var/run/docker.sock ]] || die "Docker socket /var/run/docker.sock is not available"
}

nvidia_runtime_ready() {
  command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi -L >/dev/null 2>&1 \
    && command -v nvidia-container-cli >/dev/null 2>&1 \
    && nvidia-container-cli info >/dev/null 2>&1
}

nvidia_gpu_ready() {
  command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi -L >/dev/null 2>&1
}

nvidia_xorg_ready() {
  nvidia_gpu_ready \
    && command -v Xorg >/dev/null 2>&1 \
    && [[ -r /usr/lib/xorg/modules/drivers/nvidia_drv.so ]]
}

nvidia_driver_major() {
  local version
  version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n 1)"
  [[ "$version" =~ ^[0-9]+ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[0]}"
}

ensure_nvidia_xorg_driver() {
  local major package

  nvidia_gpu_ready || die "Native hardware acceleration requires a healthy NVIDIA GPU"
  command -v Xorg >/dev/null 2>&1 || die "Native hardware acceleration requires Xorg"
  if [[ -r /usr/lib/xorg/modules/drivers/nvidia_drv.so ]]; then
    return 0
  fi

  major="$(nvidia_driver_major)" || die "Could not determine NVIDIA driver major version for Xorg driver install"
  for package in "xserver-xorg-video-nvidia-${major}" "xserver-xorg-video-nvidia-${major}-server"; do
    if apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" { found = 1 } END { exit(found ? 0 : 1) }'; then
      log "Installing NVIDIA Xorg driver package for native hardware mode: ${package}"
      apt_install "$package"
      break
    fi
  done

  nvidia_xorg_ready || die "Native hardware acceleration requires the NVIDIA Xorg driver at /usr/lib/xorg/modules/drivers/nvidia_drv.so"
}

nvidia_xorg_bus_id() {
  local pci domain bus slot func
  pci="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader,nounits 2>/dev/null | head -n 1)"
  [[ -n "$pci" ]] || return 1
  IFS=':.' read -r domain bus slot func <<<"$pci"
  [[ -n "$bus" && -n "$slot" && -n "$func" ]] || return 1
  printf 'PCI:%d:%d:%d\n' "$((16#$bus))" "$((16#$slot))" "$((16#$func))"
}

nvidia_accelerator_summary() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L 2>/dev/null | paste -sd '; ' -
  fi
}

log_acceleration_resolution() {
  local acceleration="$1"
  local accelerator_summary

  log "Selkies acceleration requested: ${SELKIES_ACCELERATION}; resolved: ${acceleration}"
  if [[ "$acceleration" == "hardware" ]]; then
    accelerator_summary="$(nvidia_accelerator_summary)"
    if [[ -n "$accelerator_summary" ]]; then
      log "Detected NVIDIA hardware accelerator(s): ${accelerator_summary}"
    else
      log "Detected NVIDIA hardware accelerator(s): <nvidia-smi unavailable despite hardware mode>"
    fi
    if [[ "$SELKIES_DEPLOYMENT" == "container" ]]; then
      log "NVIDIA container runtime: available"
    fi
    if [[ "$SELKIES_ACCELERATION" == "auto" ]]; then
      if [[ "$SELKIES_DEPLOYMENT" == "container" ]]; then
        log "Hardware acceleration selected because auto mode found a healthy NVIDIA GPU and NVIDIA container runtime."
      else
        log "Hardware acceleration selected because auto mode found a healthy NVIDIA GPU."
      fi
    else
      log "Hardware acceleration selected because SELKIES_ACCELERATION=hardware was requested and prerequisites passed."
    fi
  elif [[ "$SELKIES_ACCELERATION" == "auto" ]]; then
    if [[ "$SELKIES_DEPLOYMENT" == "container" ]]; then
      log "Software acceleration selected because auto mode did not find both a healthy NVIDIA GPU and NVIDIA container runtime."
    else
      log "Software acceleration selected because auto mode did not find a healthy NVIDIA GPU."
    fi
  else
    log "Software acceleration selected because SELKIES_ACCELERATION=software was requested."
  fi
}

resolve_acceleration() {
  case "$SELKIES_ACCELERATION" in
    hardware)
      if [[ "$SELKIES_DEPLOYMENT" == "container" ]]; then
        nvidia_runtime_ready || die "SELKIES_ACCELERATION=hardware requires a healthy NVIDIA GPU and NVIDIA container runtime"
      else
        nvidia_gpu_ready || die "SELKIES_ACCELERATION=hardware requires a healthy NVIDIA GPU"
      fi
      printf '%s\n' hardware
      ;;
    software)
      printf '%s\n' software
      ;;
    auto)
      if [[ "$SELKIES_DEPLOYMENT" == "container" ]] && nvidia_runtime_ready; then
        printf '%s\n' hardware
      elif [[ "$SELKIES_DEPLOYMENT" == "native" ]] && nvidia_gpu_ready; then
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

resolve_image() {
  local acceleration="$1"
  if [[ -n "$SELKIES_IMAGE" ]]; then
    printf '%s\n' "$SELKIES_IMAGE"
    return 0
  fi
  case "$acceleration" in
    hardware) printf '%s\n' "$SELKIES_HARDWARE_IMAGE" ;;
    software) printf '%s\n' "$SELKIES_SOFTWARE_IMAGE" ;;
  esac
}

log_image_resolution() {
  local acceleration="$1"
  local image="$2"

  if [[ -n "$SELKIES_IMAGE" ]]; then
    log "Selkies image selected from SELKIES_IMAGE override: ${image}"
  elif [[ "$acceleration" == "hardware" ]]; then
    log "Selkies image selected for hardware acceleration: ${image}"
  else
    log "Selkies image selected for software acceleration: ${image}"
  fi
}

resolve_turn_password() {
  if [[ -n "$SELKIES_TURN_PASSWORD" ]]; then
    printf '%s\n' "$SELKIES_TURN_PASSWORD"
    return 0
  fi
  if [[ -r /etc/brev-selkies-desktop/native.env ]]; then
    awk -F= '$1 == "SELKIES_TURN_PASSWORD" { print substr($0, index($0, "=") + 1); found=1 } END { exit(found ? 0 : 1) }' /etc/brev-selkies-desktop/native.env 2>/dev/null && return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
    printf '\n'
  fi
}

resolve_network() {
  if [[ "$SELKIES_DOCKER_NETWORK" == "auto" ]]; then
    printf '%s\n' bridge
  else
    printf '%s\n' "$SELKIES_DOCKER_NETWORK"
  fi
}

latest_selkies_version() {
  local tag
  tag="$(curl -fsSL --max-time 10 https://api.github.com/repos/selkies-project/selkies/releases/latest \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
    | head -n 1)"
  [[ -n "$tag" ]] || die "Could not resolve latest Selkies release version"
  printf '%s\n' "$tag"
}

resolve_install_version() {
  case "$SELKIES_DEPLOYMENT" in
    container)
      printf '%s\n' "${SELKIES_TAG:-$(ubuntu_version)}"
      ;;
    native)
      printf '%s\n' "${SELKIES_NATIVE_VERSION:-$(latest_selkies_version)}"
      ;;
  esac
}

resolve_native_x_server() {
  local acceleration="$1"
  case "$SELKIES_NATIVE_X_SERVER" in
    nvidia)
      nvidia_xorg_ready || die "SELKIES_NATIVE_X_SERVER=nvidia requires Xorg and the NVIDIA Xorg driver"
      printf '%s\n' nvidia
      ;;
    xvfb)
      printf '%s\n' xvfb
      ;;
    auto)
      if [[ "$acceleration" == "hardware" ]]; then
        nvidia_xorg_ready || die "Native hardware acceleration requires NVIDIA Xorg; refusing to run hardware mode on Xvfb"
        printf '%s\n' nvidia
      else
        printf '%s\n' xvfb
      fi
      ;;
  esac
}

write_nvidia_xorg_config() {
  local bus_id="$1"
  local config_path="$2"
  cat > "$config_path" <<EOF
Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection

Section "Device"
    Identifier "Device0"
    Driver "nvidia"
    BusID "${bus_id}"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "VirtualHeads" "1"
EndSection

Section "Monitor"
    Identifier "Monitor0"
    Option "DPMS" "false"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    Monitor "Monitor0"
    DefaultDepth 24
    Option "AllowEmptyInitialConfiguration" "true"
    Option "MetaModes" "${SELKIES_DISPLAY_WIDTH}x${SELKIES_DISPLAY_HEIGHT} +0+0"
    Option "UseEdidDpi" "False"
    Option "DPI" "96 x 96"
    SubSection "Display"
        Depth 24
        Virtual ${SELKIES_DISPLAY_WIDTH} ${SELKIES_DISPLAY_HEIGHT}
    EndSubSection
EndSection
EOF
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

stop_existing_deployments() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop brev-selkies-native.service >/dev/null 2>&1 || true
    systemctl stop coturn >/dev/null 2>&1 || true
  fi
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$SELKIES_CONTAINER_NAME" >/dev/null 2>&1 || true
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
SELKIES_HARDWARE_IMAGE=${SELKIES_HARDWARE_IMAGE}
SELKIES_SOFTWARE_IMAGE=${SELKIES_SOFTWARE_IMAGE}
SELKIES_TAG=${tag}
SELKIES_DEPLOYMENT=${SELKIES_DEPLOYMENT}
SELKIES_HOST_DOCKER=${SELKIES_HOST_DOCKER}
SELKIES_MODE=${SELKIES_MODE}
SELKIES_ACCELERATION=${SELKIES_ACCELERATION}
SELKIES_DOCKER_NETWORK=${SELKIES_DOCKER_NETWORK}
SELKIES_NATIVE_USER=${SELKIES_NATIVE_USER}
SELKIES_NATIVE_DISPLAY=${SELKIES_NATIVE_DISPLAY}
SELKIES_NATIVE_VERSION=${SELKIES_NATIVE_VERSION}
SELKIES_NATIVE_X_SERVER=${SELKIES_NATIVE_X_SERVER}
SELKIES_WEB_PORT=${SELKIES_WEB_PORT}
SELKIES_TURN_PORT=${SELKIES_TURN_PORT}
SELKIES_TURN_MIN_PORT=${SELKIES_TURN_MIN_PORT}
SELKIES_TURN_MAX_PORT=${SELKIES_TURN_MAX_PORT}
SELKIES_MIN_RELAY_PORT_COUNT=${SELKIES_MIN_RELAY_PORT_COUNT}
EOF
}

install_native_desktop() {
  local version="$1"
  local acceleration="$2"
  local encoder="$3"
  local turn_password native_group native_x_server nvidia_bus_id

  if [[ "$SELKIES_MODE" != "webrtc" ]]; then
    die "SELKIES_DEPLOYMENT=native currently supports SELKIES_MODE=webrtc only"
  fi
  id "$SELKIES_NATIVE_USER" >/dev/null 2>&1 || die "SELKIES_NATIVE_USER '${SELKIES_NATIVE_USER}' does not exist"
  native_group="$(id -gn "$SELKIES_NATIVE_USER")"
  turn_password="$(resolve_turn_password)"
  SELKIES_TURN_PASSWORD="$turn_password"

  log "Installing native Selkies host desktop for user ${SELKIES_NATIVE_USER}"
  log "Native mode installs host XFCE, portable Selkies-GStreamer, coturn, and systemd services."
  log "Native mode leaves Docker on the Brev host; users are not inside a desktop container."
  apt_install \
    jq tar gzip ca-certificates curl openssl coturn \
    dbus-x11 xfce4 xfce4-terminal xterm \
    libpulse0 pulseaudio wayland-protocols libwayland-dev libwayland-egl1 \
    x11-utils x11-xkb-utils x11-xserver-utils xserver-xorg-core \
    libx11-xcb1 libxcb-dri3-0 libxkbcommon0 libxdamage1 libxfixes3 \
    libxv1 libxtst6 libxext6 xvfb mesa-utils
  install_firefox_deb
  ensure_docker
  if [[ "$acceleration" == "hardware" ]]; then
    ensure_nvidia_xorg_driver
  fi
  native_x_server="$(resolve_native_x_server "$acceleration")"
  log "Native X server requested: ${SELKIES_NATIVE_X_SERVER}; resolved: ${native_x_server}"

  log "Downloading Selkies-GStreamer portable release v${version}"
  rm -rf "$SELKIES_NATIVE_DIR"
  curl -fsSL "https://github.com/selkies-project/selkies/releases/download/v${version}/selkies-gstreamer-portable-v${version}_amd64.tar.gz" \
    | tar -xzf - -C /opt
  [[ -x "${SELKIES_NATIVE_DIR}/selkies-gstreamer-run" ]] || die "Selkies portable runner was not installed at ${SELKIES_NATIVE_DIR}/selkies-gstreamer-run"

  mkdir -p /etc/brev-selkies-desktop
  chmod 755 /etc/brev-selkies-desktop
  if [[ "$native_x_server" == "nvidia" ]]; then
    nvidia_bus_id="$(nvidia_xorg_bus_id)" || die "Could not resolve NVIDIA Xorg BusID"
    log "Writing NVIDIA Xorg config with BusID ${nvidia_bus_id}"
    write_nvidia_xorg_config "$nvidia_bus_id" /etc/brev-selkies-desktop/xorg-nvidia.conf
  fi
  cat > /etc/brev-selkies-desktop/native.env <<EOF
SELKIES_NATIVE_USER=${SELKIES_NATIVE_USER}
SELKIES_WEB_PORT=${SELKIES_WEB_PORT}
SELKIES_MODE=${SELKIES_MODE}
SELKIES_ACCELERATION=${acceleration}
SELKIES_ENCODER=${encoder}
SELKIES_NATIVE_DISPLAY=${SELKIES_NATIVE_DISPLAY}
SELKIES_NATIVE_DIR=${SELKIES_NATIVE_DIR}
SELKIES_NATIVE_X_SERVER=${native_x_server}
SELKIES_ENABLE_BASIC_AUTH=${SELKIES_ENABLE_BASIC_AUTH}
SELKIES_BASIC_AUTH_USER=${SELKIES_BASIC_AUTH_USER}
SELKIES_BASIC_AUTH_PASSWORD=${REMOTE_DESKTOP_PASSWORD}
SELKIES_TURN_HOST=${SELKIES_TURN_HOST}
SELKIES_TURN_PORT=${SELKIES_TURN_PORT}
SELKIES_TURN_PROTOCOL=${SELKIES_TURN_PROTOCOL}
SELKIES_TURN_USERNAME=${SELKIES_TURN_USERNAME}
SELKIES_TURN_PASSWORD=${SELKIES_TURN_PASSWORD}
SELKIES_DISPLAY_WIDTH=${SELKIES_DISPLAY_WIDTH}
SELKIES_DISPLAY_HEIGHT=${SELKIES_DISPLAY_HEIGHT}
EOF
  chown "root:${native_group}" /etc/brev-selkies-desktop/native.env
  chmod 640 /etc/brev-selkies-desktop/native.env

  cat > /etc/turnserver.conf <<EOF
listening-ip=0.0.0.0
listening-ip=::
listening-port=${SELKIES_TURN_PORT}
realm=${SELKIES_TURN_REALM}
lt-cred-mech
user=${SELKIES_TURN_USERNAME}:${SELKIES_TURN_PASSWORD}
min-port=${SELKIES_TURN_MIN_PORT}
max-port=${SELKIES_TURN_MAX_PORT}
no-software-attribute
no-rfc5780
no-stun-backward-compatibility
response-origin-only-with-rfc5780
EOF
  if [[ -n "$SELKIES_TURN_EXTERNAL_IP" ]]; then
    printf 'external-ip=%s\n' "$SELKIES_TURN_EXTERNAL_IP" >> /etc/turnserver.conf
  fi
  if grep -q '^#\?TURNSERVER_ENABLED=' /etc/default/coturn; then
    sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  else
    printf 'TURNSERVER_ENABLED=1\n' >> /etc/default/coturn
  fi
  systemctl enable --now coturn
  systemctl restart coturn

  cat > /usr/local/bin/brev-selkies-native-start <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

. /etc/brev-selkies-desktop/native.env

export DISPLAY="${SELKIES_NATIVE_DISPLAY}"

if [[ ! -S "/tmp/.X11-unix/X${DISPLAY#*:}" ]]; then
  if [[ "${SELKIES_NATIVE_X_SERVER}" == "nvidia" ]]; then
    rm -f "/tmp/.X${DISPLAY#*:}-lock" "/tmp/.X11-unix/X${DISPLAY#*:}"
    Xorg "${DISPLAY}" \
      -noreset \
      -nolisten tcp \
      -ac \
      -config /etc/brev-selkies-desktop/xorg-nvidia.conf \
      -logfile /var/log/brev-selkies-xorg.log \
      >/var/log/brev-selkies-xorg.stdout 2>&1 &
  else
    Xvfb "${DISPLAY}" \
      -screen 0 "${SELKIES_DISPLAY_WIDTH}x${SELKIES_DISPLAY_HEIGHT}x24" \
      +extension COMPOSITE +extension DAMAGE +extension GLX +extension RANDR \
      +extension RENDER +extension MIT-SHM +extension XFIXES +extension XTEST \
      +iglx +render -nolisten tcp -ac -noreset \
      >/tmp/Xvfb_selkies.log 2>&1 &
  fi
fi

until [[ -S "/tmp/.X11-unix/X${DISPLAY#*:}" ]]; do
  sleep 0.5
done

if [[ "${SELKIES_NATIVE_X_SERVER}" == "nvidia" ]] && command -v xrandr >/dev/null 2>&1; then
  desired_mode="${SELKIES_DISPLAY_WIDTH}x${SELKIES_DISPLAY_HEIGHT}"
  output_name=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    output_name="$(xrandr --query 2>/dev/null | awk '/ connected/{print $1; exit}' || true)"
    [[ -n "${output_name}" ]] && break
    sleep 0.5
  done
  if [[ -n "${output_name}" ]]; then
    if xrandr --query 2>/dev/null | awk -v out="${output_name}" -v mode="${desired_mode}" '
      $1 == out { in_output = 1; next }
      in_output && /^[^[:space:]]/ { in_output = 0 }
      in_output && $1 == mode { found = 1 }
      END { exit(found ? 0 : 1) }
    '; then
      xrandr --output "${output_name}" --mode "${desired_mode}" --pos 0x0 --primary >/dev/null 2>&1 || true
    fi
  fi
fi

exec runuser -u "${SELKIES_NATIVE_USER}" -- /usr/local/bin/brev-selkies-user-session
EOF
  chmod 755 /usr/local/bin/brev-selkies-native-start

  cat > /usr/local/bin/brev-selkies-user-session <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

. /etc/brev-selkies-desktop/native.env

export DISPLAY="${SELKIES_NATIVE_DISPLAY}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/selkies-runtime-${USER}}"
export PIPEWIRE_LATENCY="128/48000"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-${XDG_RUNTIME_DIR}}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-${XDG_RUNTIME_DIR}/pulse}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_RUNTIME_PATH}/native}"

mkdir -p "${XDG_RUNTIME_DIR}" "${PULSE_RUNTIME_PATH}"
chmod 700 "${XDG_RUNTIME_DIR}" "${PULSE_RUNTIME_PATH}" 2>/dev/null || true

pulseaudio -k >/dev/null 2>&1 || true
pulseaudio --log-target=file:/tmp/pulseaudio_selkies.log --disallow-exit >/dev/null 2>&1 &

if ! pgrep -u "$(id -u)" -f "xfce4-session" >/dev/null 2>&1; then
  dbus-launch --exit-with-session xfce4-session >/tmp/xfce4_selkies.log 2>&1 &
fi

if [[ -r "${SELKIES_NATIVE_DIR}/gst-env" ]]; then
  # shellcheck disable=SC1091
  . "${SELKIES_NATIVE_DIR}/gst-env"
fi

exec "${SELKIES_NATIVE_DIR}/selkies-gstreamer-run" \
  --addr=0.0.0.0 \
  --port="${SELKIES_WEB_PORT}" \
  --enable_https=false \
  --enable_basic_auth="${SELKIES_ENABLE_BASIC_AUTH}" \
  --basic_auth_user="${SELKIES_BASIC_AUTH_USER}" \
  --basic_auth_password="${SELKIES_BASIC_AUTH_PASSWORD}" \
  --encoder="${SELKIES_ENCODER}" \
  --enable_resize=true \
  --turn_host="${SELKIES_TURN_HOST}" \
  --turn_port="${SELKIES_TURN_PORT}" \
  --turn_protocol="${SELKIES_TURN_PROTOCOL}" \
  --turn_username="${SELKIES_TURN_USERNAME}" \
  --turn_password="${SELKIES_TURN_PASSWORD}"
EOF
  chmod 755 /usr/local/bin/brev-selkies-user-session

  cat > /etc/systemd/system/brev-selkies-native.service <<EOF
[Unit]
Description=Brev Selkies Native Desktop
After=network-online.target coturn.service docker.service
Wants=network-online.target coturn.service docker.service

[Service]
Type=simple
WorkingDirectory=/root
ExecStart=/usr/local/bin/brev-selkies-native-start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable brev-selkies-native.service
  systemctl restart brev-selkies-native.service
}

install_container_desktop() {
  local version image image_ref acceleration encoder network
  version="$1"
  acceleration="$2"
  encoder="$3"
  image="$(resolve_image "$acceleration")"
  image_ref="${image}:${version}"
  network="$(resolve_network)"

  ensure_docker

  log "Installing Selkies desktop from ${image_ref}"
  log "Selkies transport mode requested: ${SELKIES_MODE}; Docker network requested: ${SELKIES_DOCKER_NETWORK}; resolved Docker network: ${network}"
  log_image_resolution "$acceleration" "$image"
  log "Selkies encoder selected: ${encoder}"

  local network_args=()
  if [[ "$network" == "host" ]]; then
    network_args=( --network host )
  fi

  # shellcheck disable=SC2206
  local port_args=( $(docker_port_args "$network") )
  local gpu_args=()
  local host_docker_args=()
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

  if is_truthy "$SELKIES_HOST_DOCKER"; then
    ensure_docker_for_desktop
    log "Host Docker is enabled inside the desktop container."
    log "WARNING: /var/run/docker.sock gives the desktop root-equivalent control over Docker on the Brev host."
    host_docker_args+=(
      -v /var/run/docker.sock:/var/run/docker.sock
      --group-add "$(stat -c '%g' /var/run/docker.sock)"
    )
    env_args+=( -e "DOCKER_HOST=unix:///var/run/docker.sock" )
    if [[ -x /usr/bin/docker ]]; then
      host_docker_args+=( -v /usr/bin/docker:/usr/bin/docker:ro )
    fi
  fi

  log "Running: docker pull ${image_ref}"
  docker pull "$image_ref"
  log "Starting container ${SELKIES_CONTAINER_NAME}"
  docker run -d \
    --name "$SELKIES_CONTAINER_NAME" \
    --restart unless-stopped \
    "${gpu_args[@]}" \
    "${network_args[@]}" \
    "${host_docker_args[@]}" \
    --tmpfs /dev/shm:rw \
    "${env_args[@]}" \
    "${port_args[@]}" \
    "$image_ref"
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

  local version acceleration encoder
  version="$(resolve_install_version)"
  acceleration="$(resolve_acceleration)"
  encoder="$(resolve_encoder "$acceleration")"

  log "Selkies deployment requested: ${SELKIES_DEPLOYMENT}"
  log_acceleration_resolution "$acceleration"
  log "Selkies encoder selected: ${encoder}"

  resolve_turn_host
  configure_ufw
  stop_existing_deployments
  require_tcp_port_free "$SELKIES_WEB_PORT"
  if [[ "$SELKIES_MODE" == "webrtc" ]] && { is_truthy "$SELKIES_TURN_ENABLE_TCP" || [[ "$SELKIES_TURN_PROTOCOL" == "tcp" ]]; }; then
    require_tcp_port_free "$SELKIES_TURN_PORT"
  fi

  case "$SELKIES_DEPLOYMENT" in
    container) install_container_desktop "$version" "$acceleration" "$encoder" ;;
    native) install_native_desktop "$version" "$acceleration" "$encoder" ;;
  esac

  healthcheck
  log "Selkies desktop is ready. Expose ${SELKIES_WEB_PORT}/tcp as the Brev Secure Link."
  if [[ "$SELKIES_MODE" == "webrtc" ]]; then
    log "Also expose ${SELKIES_TURN_PORT}/udp and ${SELKIES_TURN_MIN_PORT}-${SELKIES_TURN_MAX_PORT}/udp for WebRTC TURN."
  fi
}

main "$@"
