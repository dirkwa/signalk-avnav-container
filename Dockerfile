# syntax=docker/dockerfile:1
#
# AvNav packaged as a slim, non-root, signalk-container-compatible image.
#
# Design notes:
#  - debian:bookworm-slim base (glibc). The base suite matches FREEX_SUITE so the
#    free-x apt repo and the runtime libc line up. AvNav is pure-Python and ships
#    as an arch-independent (_all) .deb, so one package serves every platform; we
#    still build multi-arch because the Python *runtime* underneath differs per arch.
#  - Runs as a dedicated non-root user with a real, writable HOME and a writable /tmp,
#    and never chmod/chowns bind-mounts in the entrypoint — this is exactly the
#    contract signalk-container's UID-alignment requires (see its plugin dev guide).
#  - tini as PID 1 == the `init: true` that HaLOS sets on its own AvNav container,
#    giving clean SIGTERM shutdown and zombie reaping.

ARG DEBIAN_BASE=debian:bookworm-slim
FROM ${DEBIAN_BASE}

# --- Build-time knobs -------------------------------------------------------
# AVNAV_VERSION is the upstream AvNav package version (date-based, e.g. 20251028).
# It is injected by CI and used for the OCI label + image tag. When the free-x repo
# exposes that exact version it is also used to pin the apt install; otherwise the
# latest in the suite is taken and CI tags the image with whatever version landed.
ARG AVNAV_VERSION=latest

# free-x publishes the AvNav packages. The bookworm suite is the current published
# one; keep DEBIAN_BASE on the matching Debian release.
ARG FREEX_SUITE=bookworm

# Runtime user. 1000:1000 is the common Signal K host UID on Raspberry Pi OS / Debian.
# The plugin declares `user: { inImageUid: 1000, inImageGid: 1000 }` matching these so
# rootless Podman remaps in-container ownership back to the Signal K host user.
ARG AVNAV_UID=1000
ARG AVNAV_GID=1000

LABEL org.opencontainers.image.title="signalk-avnav-container" \
      org.opencontainers.image.description="AvNav (wellenvogel) as a non-root, signalk-container-managed image" \
      org.opencontainers.image.source="https://github.com/dirkwa/signalk-avnav-container" \
      org.opencontainers.image.licenses="MIT" \
      net.wellenvogel.avnav.version="${AVNAV_VERSION}"

ENV PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive

# --- Create the runtime user BEFORE installing AvNav ------------------------
# Ordering matters: AvNav's postinst may `adduser avnav`. Creating the user first
# means it reuses ours (with the UID we want) instead of allocating a system UID.
RUN set -eux; \
    groupadd -g "${AVNAV_GID}" avnav; \
    useradd -m -u "${AVNAV_UID}" -g "${AVNAV_GID}" -s /bin/sh -d /home/avnav avnav

# --- Install AvNav from the free-x apt repository ---------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg tini \
        python3 python3-serial; \
    # free-x signing key + source
    curl -fsSL https://www.free-x.de/debian/oss.boating.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/oss.boating.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/oss.boating.gpg] https://www.free-x.de/debian ${FREEX_SUITE} main contrib non-free" \
        > /etc/apt/sources.list.d/boating.list; \
    apt-get update; \
    # Pin to AVNAV_VERSION when the repo actually exposes that exact version;
    # otherwise fall back to the latest in the suite. The free-x suite usually
    # keeps only its current release, so a stale/未-published pin must NOT hard-fail.
    # NOTE: `apt-cache show avnav=VER` exits 0 even for an absent version (it
    # matches the virtual "referred to by another package" stub), so test the
    # madison version list for an exact match instead.
    if [ "${AVNAV_VERSION}" != "latest" ] && \
       apt-cache madison avnav 2>/dev/null | awk '{print $3}' | grep -qx "${AVNAV_VERSION}"; then \
        echo "Installing pinned avnav=${AVNAV_VERSION}"; \
        apt-get install -y --no-install-recommends "avnav=${AVNAV_VERSION}"; \
    else \
        echo "avnav=${AVNAV_VERSION} not in suite — installing latest available"; \
        apt-get install -y --no-install-recommends avnav; \
    fi; \
    # Record what actually got installed (CI reads this to tag the image).
    dpkg-query -W -f='${Version}\n' avnav > /etc/avnav.version; \
    # NOTE: we deliberately do NOT enable the avnav systemd service — in a container
    # the server is PID-managed by tini, configured via the entrypoint below.
    apt-get purge -y --auto-remove gnupg; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Alternative install (strict version pinning / offline-archived builds):
# instead of the apt block above, download the exact archived .deb and install it.
# The release archive keeps old versions, so this pins reproducibly:
#
#   ARG AVNAV_DEB_URL=https://www.wellenvogel.net/software/avnav/downloads/release/${AVNAV_VERSION}/avnav_${AVNAV_VERSION}_all.deb
#   RUN curl -fsSL "${AVNAV_DEB_URL}" -o /tmp/avnav.deb \
#    && apt-get update \
#    && apt-get install -y --no-install-recommends /tmp/avnav.deb \
#    && rm -f /tmp/avnav.deb && rm -rf /var/lib/apt/lists/*
# ---------------------------------------------------------------------------

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# AvNav data lives entirely on a bind-mounted host volume (charts, routes, tracks,
# avnav_server.xml). Nothing valuable is stored inside the container layer.
ENV HOME=/home/avnav \
    AVNAV_DATADIR=/home/avnav/avnav \
    AVNAV_PORT=8080
# AVNAV_CHARTBASE is optional: when set (by the plugin, from a user-configured host
# chart dir mounted into the container), the entrypoint passes it to avnav with -c.

USER avnav
WORKDIR /home/avnav

EXPOSE 8080

# AvNav's web entrypoint. curl is in the image; the probe runs inside the container,
# so it targets the in-container port, not the host mapping.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${AVNAV_PORT}/viewer/avnav_viewer.html" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
