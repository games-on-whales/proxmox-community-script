#!/usr/bin/env bash
# Wolf Den must talk to Wolf's own socket under a non-default XDG_RUNTIME_DIR,
# with no socat proxy and with real (ICU) globalization. Runs the launcher
# against a fake Wolf API and a stub dotnet. No container required.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'kill "${API_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
RUNTIME="$TMP/custom-runtime"
mkdir -p "$RUNTIME" "$TMP/bin"

python3 - "$RUNTIME/wolf.sock" <<'PYAPI' &
import http.server, os, socketserver, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"[]")
    def log_message(self, *args): pass
    def address_string(self): return "wolf"
class Server(socketserver.UnixStreamServer):
    def get_request(self):
        request, _ = super().get_request()
        return request, ("wolf", 0)
Server(sys.argv[1], Handler).serve_forever()
PYAPI
API_PID=$!

cat > "$TMP/bin/dotnet" <<'STUB'
#!/usr/bin/env bash
env | grep -E '^(WOLF_SOCKET_PATH|DOTNET_SYSTEM_GLOBALIZATION_INVARIANT)=' || true
pgrep -x socat >/dev/null && echo SOCAT_RUNNING || true
STUB
cat > "$TMP/bin/socat" <<'STUB'
#!/usr/bin/env bash
echo "SOCAT_INVOKED" >&2
STUB
chmod +x "$TMP/bin/dotnet" "$TMP/bin/socat"

OUT=$(env -u DOTNET_SYSTEM_GLOBALIZATION_INVARIANT PATH="$TMP/bin:$PATH" \
  XDG_RUNTIME_DIR="$RUNTIME" bash wolf-den-launch.sh 2>&1)
grep -qx "WOLF_SOCKET_PATH=unix://$RUNTIME/wolf.sock" <<<"$OUT" ||
  { echo "FAIL: WOLF_SOCKET_PATH does not point at Wolf's socket"; echo "$OUT"; exit 1; }
if grep -q 'DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=\|SOCAT_' <<<"$OUT"; then
  echo "FAIL: launcher still sets invariant globalization or starts socat"; echo "$OUT"; exit 1
fi
echo 'PASS: Wolf Den uses Wolf socket directly, ICU globalization, custom XDG_RUNTIME_DIR'
