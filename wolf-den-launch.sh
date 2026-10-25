#!/usr/bin/env bash
# Wolf Den (WolfLeash) — web UI for managing Wolf on :8080. Started in the
# background by /opt/wolf-den/entrypoint.sh. Wolf Den runs inside this
# plugin's Wolf container (plugins are single-container), so it reaches Wolf's
# API socket locally. Wolf creates that socket at ${XDG_RUNTIME_DIR}/wolf.sock
# (api.cpp default). The upstream wolf-den image fronts it with a socat proxy
# because dotnet runs there as UID 1000 via gosu; here dotnet runs as root and
# opens Wolf's socket directly, so there is no proxy process to die.
set -u

SOCK="${XDG_RUNTIME_DIR:-/run/user/wolf}/wolf.sock"
echo "[wolf-den] waiting for Wolf API socket at ${SOCK}"
# A socket pathname can survive a CT restart; wait for a successful API response.
if ! python3 - "${SOCK}" <<'PYREADY'
import http.client
import socket
import sys
import time

for attempt in range(180):
    connection = http.client.HTTPConnection("localhost", timeout=2)
    try:
        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.sock.settimeout(2)
        connection.sock.connect(sys.argv[1])
        connection.request("GET", "/api/v1/apps")
        response = connection.getresponse()
        if response.status == 200:
            response.read()
            break
    except (OSError, http.client.HTTPException):
        pass
    finally:
        connection.close()
    time.sleep(1)
else:
    sys.exit("Wolf API did not become ready")
PYREADY
then
  echo "[wolf-den] Wolf API never became ready; not starting" >&2
  exit 1
fi

export WOLF_SOCKET_PATH="unix://${SOCK}"
export ASPNETCORE_URLS="http://0.0.0.0:8080"

cd /opt/wolf-den
echo "[wolf-den] starting WolfLeash on :8080"
exec dotnet /opt/wolf-den/WolfLeash.dll
