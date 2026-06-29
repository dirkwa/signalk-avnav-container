# signalk-avnav-container

[AvNav](https://www.wellenvogel.net/software/avnav/) packaged as a slim, non-root
OCI image that the [`signalk-avnav`](https://github.com/dirkwa/signalk-avnav) plugin
runs via [`signalk-container`](https://github.com/dirkwa/signalk-container).

This repo owns **only the image**. The plugin owns running it, wiring it into the
Signal K admin UI, and the update UX.

## What it produces

`ghcr.io/dirkwa/signalk-avnav-container:<avnav-version>` (+ `:latest`, `:sha-…`),
multi-arch (`linux/amd64`, `linux/arm64`).

## Image contract

Built to satisfy signalk-container's UID-alignment requirements:

- runs as a dedicated non-root user (`avnav`, uid/gid `1000`) with a writable `HOME`
- writable `/tmp`, no `chmod`/`chown` of bind mounts in the entrypoint
- `tini` as PID 1 for clean `SIGTERM` shutdown (the `init: true` equivalent)
- all state on a bind-mounted host volume (`/home/avnav/avnav`)

The plugin therefore declares `user: { inImageUid: 1000, inImageGid: 1000 }`.

## How it stays current

1. Bump `.avnav-version` on `main` by hand to the AvNav version you want.
2. That push runs `build.yml`: multi-arch build → GHCR → Trivy scan →
   **GitHub Release** `v<version>`.
3. The plugin's update check watches those releases and notifies Signal K.

(There is intentionally no automated upstream watcher — version bumps are a
deliberate, reviewed act.)

## Build locally

```bash
docker buildx build --platform linux/arm64 \
  --build-arg AVNAV_VERSION=20250822 \
  -t signalk-avnav-container:test --load .
```

## Harmless startup logs

AvNav logs a couple of errors on start that are expected in a container and do not affect
the web UI or the Signal K connection:

- `[19] Avahi … name 'GLib' is not defined` — AvNav's mDNS/Avahi service announcer needs the
  GLib/`python3-gi` bindings and a running `avahi-daemon`, neither of which is in this slim
  image. mDNS announcement is not used here (devices reach AvNav by its known host:port), so
  the announcer is intentionally left out rather than pulling in the GLib stack.
- `bluetooth error [Errno 97]` / `unable to connect at n2kd localhost:2598` — optional inputs
  (BT GPS, a local n2kd) that aren't present in the container.

## Notes for this environment

- **free-x `bookworm` suite**: the base image (`debian:bookworm-slim`) is kept on the
  same Debian release as `FREEX_SUITE` so the apt repo and the runtime libc line up.
  The `avnav` package is arch-independent (`_all`) pure Python.
- **Strict version pinning**: the free-x suite usually keeps only the latest version.
  For reproducible historical builds use the archived-`.deb` install block (commented
  in the `Dockerfile`).
