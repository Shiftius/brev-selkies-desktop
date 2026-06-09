# Brev Selkies Desktop

Minimal Launchable assets for running a browser-based Selkies desktop on Brev.

This repository is intentionally Selkies-only. It does not include NV Streamer packages, NV Streamer service recovery, or driver-alignment logic.

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
- `hardware`: require NVIDIA GPU/container-runtime readiness, run Docker with `--gpus all`, and default `SELKIES_ENCODER=nvh264enc`.
- `software`: do not request Docker GPU access and default `SELKIES_ENCODER=x264enc`.

`SELKIES_MODE` controls the browser transport:

- `webrtc`, default: lower-latency Selkies WebRTC. Requires `8080/tcp` plus TURN UDP ports.
- `kasmvnc`: single-port fallback over `8080/tcp`.

## Ports

Default WebRTC Launchable ports:

- `8080/tcp`: Brev Secure Link, usually named `desktop`.
- `47998/udp`: Selkies internal TURN listener.
- `47999-48000/udp`: compact Selkies TURN relay range.

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

Override the image:

```bash
export SELKIES_IMAGE="ghcr.io/selkies-project/nvidia-egl-desktop"
export SELKIES_TAG="24.04"
```

Leave `SELKIES_TAG` unset to match the instance Ubuntu version (`22.04` or `24.04`).

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

## References

- [docker-selkies-egl-desktop](https://github.com/selkies-project/docker-selkies-egl-desktop)
- [Selkies encoder components](https://github.com/selkies-project/selkies/blob/main/docs/component.md)
