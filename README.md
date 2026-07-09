# Brev Selkies Desktop

Minimal Launchable assets for running a browser-based Selkies desktop on Brev.

This repository is intentionally Selkies-only. It does not include NV Streamer packages, NV Streamer service recovery, or driver-alignment logic.

The script chooses the Selkies image from the resolved acceleration mode:

- hardware acceleration: `ghcr.io/selkies-project/nvidia-glx-desktop`
- software acceleration: `ghcr.io/selkies-project/nvidia-egl-desktop`

Set `SELKIES_IMAGE` only when you need to override that automatic selection.

## Launchable Script

Use this as the Brev Launchable user script:

```bash
#!/usr/bin/env bash
set -euo pipefail

export SELKIES_ACCELERATION=auto
export SELKIES_DEPLOYMENT=container
export SELKIES_MODE=webrtc

curl -fsSL "https://raw.githubusercontent.com/Shiftius/brev-selkies-desktop/main/assets/brev-selkies-desktop.sh" | sudo -E bash
```

## Modes

`SELKIES_DEPLOYMENT` controls where the desktop runs:

- `container`, default: run the Selkies all-in-one desktop image.
- `native`: host install that runs an Ubuntu GNOME desktop, Selkies-GStreamer, coturn, and Docker directly on the Brev host with systemd services.

Container deployment also enables host Docker access by default:

```bash
export SELKIES_HOST_DOCKER=1
```

That mounts `/var/run/docker.sock` and the host Docker CLI into the desktop container so Docker commands from the desktop control the Brev host. This is convenient for ROS/dev-container workflows, but it gives the desktop root-equivalent Docker control on the host. Disable it with:

```bash
export SELKIES_HOST_DOCKER=0
```

`SELKIES_ACCELERATION` controls encode/runtime behavior:

- `auto`, default: use NVIDIA hardware acceleration when required GPU prerequisites are healthy; otherwise use software acceleration.
- `hardware`: require NVIDIA GPU readiness, default `SELKIES_ENCODER=nvh264enc`, and use the NVIDIA GLX desktop image for container mode.
- `software`: do not request Docker GPU access, default `SELKIES_ENCODER=x264enc`, and use the NVIDIA EGL desktop image for its software fallback path.

In container mode, hardware also requires a healthy NVIDIA container runtime and runs Docker with `--gpus all`. In native mode, hardware requires an NVIDIA-backed Xorg display; the script installs or verifies the matching NVIDIA Xorg driver before choosing hardware mode.

`SELKIES_MODE` controls the browser transport:

- `webrtc`, default: lower-latency Selkies WebRTC. Requires `8080/tcp` plus TURN UDP ports.
- `kasmvnc`: single-port fallback over `8080/tcp`.

## Ports

Default WebRTC Launchable ports:

- `8080/tcp`: Brev Secure Link, usually named `desktop`.
- `47998/udp`: Selkies internal TURN listener.
- `47999-48015/udp`: compact Selkies TURN relay range.

Do not shrink the relay range to only one or two ports. Reconnects can leave old TURN allocations around briefly, and a too-small relay range can fail with coturn `error 508: Cannot create socket` / `no available ports`. The script now requires at least eight relay ports by default.

For `SELKIES_MODE=kasmvnc`, expose only:

- `8080/tcp`

If TCP TURN is needed, set `SELKIES_TURN_ENABLE_TCP=1` and also expose `47998/tcp` plus `47999-48000/tcp`.

## Common Configuration

Force hardware acceleration:

```bash
export SELKIES_ACCELERATION=hardware
```

Force software acceleration:

```bash
export SELKIES_ACCELERATION=software
```

Use single-port KasmVNC fallback:

```bash
export SELKIES_MODE=kasmvnc
```

Test native host deployment:

```bash
export SELKIES_DEPLOYMENT=native
export SELKIES_ACCELERATION=auto
export SELKIES_MODE=webrtc
```

Native mode installs `coturn` and Firefox on the host and uses the same default Launchable ports. It intentionally avoids the all-in-one Selkies desktop container so Docker commands inside the streamed desktop operate on the Brev host naturally. Firefox is installed from Mozilla's apt repository so the desktop gets a real `.deb` browser instead of Ubuntu's snap transition package.

Native mode defaults to the familiar Ubuntu GNOME desktop with Yaru styling and the left dock:

```bash
export SELKIES_NATIVE_DESKTOP=ubuntu
```

The previous lightweight desktop remains available when install size or simplicity matters more than appearance:

```bash
export SELKIES_NATIVE_DESKTOP=xfce
```

Native mode downloads the latest `selkies-project/selkies` portable release by default. Pin it when testing a specific Selkies release:

```bash
export SELKIES_NATIVE_VERSION=1.6.2
```

For hardware acceleration, native mode uses an NVIDIA-backed Xorg display by default instead of `Xvfb`, so browser workloads such as WebGL can use the GPU. Native hardware mode now refuses to run on `Xvfb`; if NVIDIA Xorg cannot be prepared, the script exits instead of starting a misleading software-rendered desktop with a hardware encoder. Override the display server only when troubleshooting:

```bash
export SELKIES_NATIVE_X_SERVER=auto
# or: nvidia, xvfb
```

Override the image selection:

```bash
export SELKIES_IMAGE="ghcr.io/selkies-project/nvidia-glx-desktop"
export SELKIES_TAG="24.04"
```

Leave `SELKIES_TAG` unset to match the instance Ubuntu version (`22.04` or `24.04`).

Override only the automatic defaults:

```bash
export SELKIES_HARDWARE_IMAGE="ghcr.io/selkies-project/nvidia-glx-desktop"
export SELKIES_SOFTWARE_IMAGE="ghcr.io/selkies-project/nvidia-egl-desktop"
```

## Authentication

The default is:

```bash
export SELKIES_ENABLE_BASIC_AUTH=false
```

That assumes access is gated by the Brev Secure Link. For direct, non-Secure-Link testing:

```bash
export SELKIES_ENABLE_BASIC_AUTH=true
export REMOTE_DESKTOP_PASSWORD="choose-a-strong-password"
```

## Validation

```bash
bash -n assets/brev-selkies-desktop.sh
SELKIES_ACCELERATION=software assets/brev-selkies-desktop.sh --print-config
SELKIES_DEPLOYMENT=native assets/brev-selkies-desktop.sh --print-config
```

## Troubleshooting

If the first stream works but refresh/reconnect later fails while the container still looks healthy, check the container log:

```bash
docker exec brev-selkies-desktop tail -n 200 /tmp/selkies-gstreamer-entrypoint.log
```

Messages such as `create_relay_ioa_sockets: no available ports` or `ALLOCATE processed, error 508: Cannot create socket` mean the exposed TURN relay range is too small. Expose the full default range, `47998-48015/udp`, and rerun the Launchable.

Selkies WebRTC is intended for one active browser session per desktop. Opening the same remote desktop from multiple browsers or users at the same time can disconnect or take over the existing session. Treat multi-user collaboration as unsupported for this Launchable, similar to the earlier NV Streamer desktop path.

## References

- [docker-selkies-egl-desktop](https://github.com/selkies-project/docker-selkies-egl-desktop)
- [docker-selkies-glx-desktop](https://github.com/selkies-project/docker-selkies-glx-desktop)
- [Selkies encoder components](https://github.com/selkies-project/selkies/blob/main/docs/component.md)
