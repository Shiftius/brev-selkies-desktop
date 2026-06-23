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
export SELKIES_MODE=webrtc

curl -fsSL "https://raw.githubusercontent.com/Shiftius/brev-selkies-desktop/main/assets/brev-selkies-desktop.sh" | sudo -E bash
```

## Modes

`SELKIES_ACCELERATION` controls encode/runtime behavior:

- `auto`, default: use NVIDIA hardware acceleration only when the GPU and NVIDIA container runtime are both healthy; otherwise use software acceleration.
- `hardware`: require NVIDIA GPU/container-runtime readiness, run Docker with `--gpus all`, default `SELKIES_ENCODER=nvh264enc`, and use the NVIDIA GLX desktop image.
- `software`: do not request Docker GPU access, default `SELKIES_ENCODER=x264enc`, and use the NVIDIA EGL desktop image for its software fallback path.

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
```

## Troubleshooting

If the first stream works but refresh/reconnect later fails while the container still looks healthy, check the container log:

```bash
docker exec brev-selkies-desktop tail -n 200 /tmp/selkies-gstreamer-entrypoint.log
```

Messages such as `create_relay_ioa_sockets: no available ports` or `ALLOCATE processed, error 508: Cannot create socket` mean the exposed TURN relay range is too small. Expose the full default range, `47998-48015/udp`, and rerun the Launchable.

## References

- [docker-selkies-egl-desktop](https://github.com/selkies-project/docker-selkies-egl-desktop)
- [docker-selkies-glx-desktop](https://github.com/selkies-project/docker-selkies-glx-desktop)
- [Selkies encoder components](https://github.com/selkies-project/selkies/blob/main/docs/component.md)
