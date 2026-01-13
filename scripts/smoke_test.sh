#!/usr/bin/env bash
#
# Smoke test script for Maraithon
# Verifies the application compiles, migrates, starts, and responds to requests
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

echo "=========================================="
echo "  Maraithon Smoke Tests"
echo "=========================================="
echo

# 1. Check dependencies
info "Checking dependencies..."
mix deps.get --quiet || fail "Failed to fetch dependencies"
pass "Dependencies OK"

# 2. Compile with warnings as errors
info "Compiling (warnings as errors)..."
MIX_ENV=test mix compile --warnings-as-errors 2>&1 || fail "Compilation failed or has warnings"
pass "Compilation OK"

# 3. Check code formatting
info "Checking code formatting..."
mix format --check-formatted 2>&1 || fail "Code is not formatted. Run 'mix format'"
pass "Formatting OK"

# 4. Run database migrations
info "Setting up test database..."
MIX_ENV=test mix ecto.drop --quiet 2>/dev/null || true
MIX_ENV=test mix ecto.create --quiet || fail "Failed to create database"
MIX_ENV=test mix ecto.migrate --quiet || fail "Failed to run migrations"
pass "Database migrations OK"

# 5. Run tests
info "Running test suite..."
MIX_ENV=test mix test || fail "Tests failed"
pass "Tests OK"

# 6. Start server and check health endpoint
info "Starting server for health check..."

# Start server in background, redirect output
MIX_ENV=dev mix phx.server > /tmp/maraithon_smoke.log 2>&1 &
SERVER_PID=$!

# Wait for server to start (check periodically)
MAX_WAIT=15
WAITED=0
SERVER_READY=false

while [ $WAITED -lt $MAX_WAIT ]; do
    sleep 1
    WAITED=$((WAITED + 1))

    # Check if process is still running
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "Server process died. Log output:"
        cat /tmp/maraithon_smoke.log
        fail "Server failed to start"
    fi

    # Try to connect
    if curl -s -o /dev/null http://localhost:4000/health 2>/dev/null; then
        SERVER_READY=true
        break
    fi
done

if [ "$SERVER_READY" = false ]; then
    kill $SERVER_PID 2>/dev/null || true
    echo "Server log:"
    cat /tmp/maraithon_smoke.log
    fail "Server did not become ready in ${MAX_WAIT}s"
fi

# Check health endpoint
info "Checking server responds..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:4000/health 2>/dev/null || echo "000")

# Kill the server
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    pass "Server responds (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" -ge 300 ] && [ "$HTTP_CODE" -lt 500 ]; then
    pass "Server responds (HTTP $HTTP_CODE - redirect/client response)"
else
    fail "Server returned error (HTTP $HTTP_CODE)"
fi

# 7. Check for common issues
info "Checking for common issues..."

# Check for TODO/FIXME in critical files (warning only)
TODOS=$(grep -r "TODO\|FIXME" lib/ --include="*.ex" 2>/dev/null | wc -l | tr -d ' ')
if [ "$TODOS" -gt 0 ]; then
    echo -e "${YELLOW}  Note: Found $TODOS TODO/FIXME comments${NC}"
fi

# Check for hardcoded secrets (should fail)
# Look for actual secret values, not variable names
if grep -rE '(sk-[a-zA-Z0-9]{20,}|"[A-Za-z0-9+/]{40,}"|ghp_[a-zA-Z0-9]{36}|xox[baprs]-[a-zA-Z0-9-]+)' lib/ --include="*.ex" 2>/dev/null | grep -q .; then
    fail "Possible hardcoded secrets found"
fi
pass "No hardcoded secrets"

echo
echo "=========================================="
echo -e "${GREEN}  All smoke tests passed!${NC}"
echo "=========================================="
