#!/usr/bin/env bash
# E2E smoke + shutdown panic/leak gate.
#
# Boots the real binary against a fresh SQLite DB, exercises the request surface
# (health probes -> metrics -> create admin -> login -> system/info), then
# SIGTERMs and asserts:
#   1. it exits within 20s (drain does not hang);
#   2. no panic in the log;
#   3. no allocator leak report (SafeAllocator leaked).
# Unit tests cannot catch "ctx.allocator (request arena) free is a no-op"
# silent leaks (both sides are testing.allocator there); only a real process's
# shutdown report can.
#
# Usage: scripts/run_e2e.sh     (requires a prior 'zig build'; needs curl)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin"
PORT="${ZASDOOR_E2E_PORT:-18117}"
WORK="$(mktemp -d /tmp/zasdoor-e2e.XXXXXX)"
LOG="$WORK/srv.log"
ADMIN_EMAIL="e2e-admin@example.com"
ADMIN_PASS="e2e-password-123"

SRV_PID=""
cleanup() {
    if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
        kill -9 "$SRV_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "e2e: FAIL - $*"
    echo "--- server log tail ---"
    tail -30 "$LOG" 2>/dev/null || true
    exit 1
}

echo "e2e: boot (workdir $WORK)"
export ZASDOOR_HTTP_PORT="$PORT"
export ZASDOOR_SQLITE_PATH="$WORK/e2e.db"
export ZASDOOR_UPLOAD_DIR="$WORK/uploads"
"$BIN/zasdoor" >"$LOG" 2>&1 &
SRV_PID=$!

up=0
for _ in $(seq 1 50); do
    if ! kill -0 "$SRV_PID" 2>/dev/null; then
        fail "server exited during startup"
    fi
    if curl -sf -m 1 "http://127.0.0.1:$PORT/health/live" >/dev/null 2>&1; then
        up=1
        break
    fi
    sleep 0.2
done
[ "$up" = 1 ] || fail "server did not become ready in 10s"

echo "e2e: probes"
curl -sf -m 3 "http://127.0.0.1:$PORT/api/v1/health/ready" >/dev/null 2>&1 || fail "health/ready"
if ! curl -sf -m 3 "http://127.0.0.1:$PORT/metrics" 2>/dev/null | grep -q zasdoor_task_processed_total; then
    fail "/metrics missing dispatcher counters"
fi

echo "e2e: admin + login + system/info"
"$BIN/zasdoor-admin" create-admin --email "$ADMIN_EMAIL" --password "$ADMIN_PASS" >/dev/null 2>&1 || fail "create-admin"
LOGIN_JSON=$(curl -sf -m 3 -X POST "http://127.0.0.1:$PORT/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}") || fail "login request"
TOKEN=$(printf '%s' "$LOGIN_JSON" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || fail "login returned no token"
if ! curl -sf -m 3 "http://127.0.0.1:$PORT/api/v1/system/info" -H "Authorization: Bearer $TOKEN" 2>/dev/null | grep -q '"version"'; then
    fail "system/info"
fi

echo "e2e: SIGTERM -> graceful drain (<=20s)"
kill -TERM "$SRV_PID"
exited=0
for _ in $(seq 1 100); do
    if ! kill -0 "$SRV_PID" 2>/dev/null; then
        exited=1
        break
    fi
    sleep 0.2
done
[ "$exited" = 1 ] || fail "server did not exit within 20s of SIGTERM"
SRV_PID=""

if grep -qi "panic" "$LOG"; then
    fail "panic found in server log"
fi
if grep -qi "leaked" "$LOG"; then
    fail "allocator leak report found in server log"
fi
echo "e2e: OK (boot -> probes -> admin/login/info -> graceful shutdown, no panic/leak)"
