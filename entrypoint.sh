#!/bin/sh
# AvNav container entrypoint.
#
# Runs the AvNav server in the foreground (so tini/PID 1 owns it) with a data dir
# on the bind-mounted host volume. Config is taken from env so signalk-container's
# drift detection (which includes env) recreates the container when the port or
# chart dir changes.
#
# Flags map to avnav_server.py's argparse:
#   -w DATADIR    base data dir
#   -o PORT       http listener port (overrides avnav_server.xml)
#   -c CHARTBASE  chart base dir (overrides the one in config)
set -eu

DATADIR="${AVNAV_DATADIR:-/home/avnav/avnav}"
PORT="${AVNAV_PORT:-8080}"

# Create the data dir if this is a first run on a fresh volume. Default umask only —
# never chmod/chown a bind mount here (that fights signalk-container's UID alignment
# and silently no-ops on FAT/exFAT USB sources anyway).
mkdir -p "${DATADIR}"

# --- Seed AvNav's SignalK connection from env -------------------------------
# AvNav's <AVNSignalKHandler> reads host/port (and, for write-back, sendData +
# userName/password) from avnav_server.xml — it does NOT read env directly. The
# plugin passes the host SignalK server's address here; we patch the handler
# stanza so AvNav connects automatically instead of failing on localhost:3000.
#
# Idempotent: only the attributes provided via env are set; uuid/migrated and any
# user edits to other elements are preserved. Runs every start so a port/cred
# change in the plugin re-applies (signalk-container recreates the container on
# env drift, so this re-runs with the new values).
if [ -n "${AVNAV_SK_HOST:-}" ]; then
    XMLFILE="${DATADIR}/avnav_server.xml"
    AVNAV_SK_HOST="${AVNAV_SK_HOST}" \
    AVNAV_SK_PORT="${AVNAV_SK_PORT:-3000}" \
    AVNAV_SK_WRITE="${AVNAV_SK_WRITE:-false}" \
    AVNAV_SK_USER="${AVNAV_SK_USER:-}" \
    AVNAV_SK_PASSWORD="${AVNAV_SK_PASSWORD:-}" \
    XMLFILE="${XMLFILE}" \
    python3 - <<'PYEOF'
import os, xml.etree.ElementTree as ET

path = os.environ["XMLFILE"]
host = os.environ["AVNAV_SK_HOST"]
port = os.environ["AVNAV_SK_PORT"]
write = os.environ.get("AVNAV_SK_WRITE", "false").lower() in ("1", "true", "yes")
user = os.environ.get("AVNAV_SK_USER", "")
password = os.environ.get("AVNAV_SK_PASSWORD", "")

if os.path.exists(path):
    tree = ET.parse(path)
    root = tree.getroot()
else:
    root = ET.Element("AVNServer")
    tree = ET.ElementTree(root)

h = root.find("AVNSignalKHandler")
if h is None:
    h = ET.SubElement(root, "AVNSignalKHandler")

# Connection (read works with just host/port even when SK security is on).
h.set("host", host)
h.set("port", str(port))
h.set("enabled", "true")

# Write-back (waypoints/routes to SignalK) needs sendData + credentials; AvNav's
# handler only authenticates via username+password login (no token flow).
h.set("sendData", "true" if write else "false")
if write and user:
    h.set("userName", user)
    h.set("password", password)

tree.write(path, xml_declaration=True, encoding="unicode")
print("[entrypoint] seeded AVNSignalKHandler host=%s port=%s write=%s" % (host, port, write))
PYEOF
fi

set -- -w "${DATADIR}" -o "${PORT}"

# Optional external chart directory (mounted by the plugin, -c == chartbase).
if [ -n "${AVNAV_CHARTBASE:-}" ]; then
    set -- "$@" -c "${AVNAV_CHARTBASE}"
fi

# Optional extra args passed straight through (e.g. -l for loglevel).
if [ -n "${AVNAV_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2086
    set -- "$@" ${AVNAV_EXTRA_ARGS}
fi

echo "[entrypoint] starting avnav: datadir=${DATADIR} port=${PORT} chartbase=${AVNAV_CHARTBASE:-<none>}"

# `avnav` is the console entry installed by the package and runs as any user.
exec avnav "$@"
