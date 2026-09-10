#!/usr/bin/env bash
# Cloud Agent install — idempotent repository bootstrap for FoodBlock.
#
# Prepares every locally runnable test suite:
#   - JS SDK        (sdk/javascript) — zero runtime deps, nothing to install
#   - Python SDK    (sdk/python)     — editable install + pytest
#   - Go SDK        (sdk/go)         — module download (populates go.sum)
#   - MCP server    (mcp)            — npm ci
#   - CLI           (cli)            — npm ci
#   - Reference srv (server)         — npm ci + a local PostgreSQL 16 instance
#
# Swift SDK tests are intentionally not covered: the Swift toolchain is not part
# of this environment's base image.
#
# Re-runnable: safe to run repeatedly against cached or partial state.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OS_USER="$(id -un)"

echo "[install] Node dependencies (mcp, server, cli)…"
( cd mcp && npm ci )
( cd server && npm ci )
( cd cli && npm ci )
# sdk/javascript has no runtime dependencies — its tests run on Node alone.

echo "[install] Python SDK (editable) + pytest…"
# Python 3.12 on this base image is PEP 668 "externally managed"; installing the
# SDK and test runner into the user/site environment requires --break-system-packages.
pip3 install --break-system-packages -e sdk/python
pip3 install --break-system-packages pytest

echo "[install] Go modules…"
( cd sdk/go && go mod download all )

echo "[install] PostgreSQL for the reference server tests…"
if ! command -v pg_ctlcluster >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-contrib
fi

# Detect the installed cluster (fall back to the Ubuntu 24.04 default of 16/main).
PG_VER="$(pg_lsclusters 2>/dev/null | awk 'NR==2{print $1}')"; : "${PG_VER:=16}"
PG_CLUSTER="$(pg_lsclusters 2>/dev/null | awk 'NR==2{print $2}')"; : "${PG_CLUSTER:=main}"
HBA="/etc/postgresql/${PG_VER}/${PG_CLUSTER}/pg_hba.conf"

# Trust loopback TCP so the server's default connection string
# (postgresql://localhost:5432/foodblock) connects without a password.
sudo sed -i -E 's|^(host\s+all\s+all\s+127\.0\.0\.1/32\s+)\S+|\1trust|' "$HBA"
sudo sed -i -E 's|^(host\s+all\s+all\s+::1/128\s+)\S+|\1trust|' "$HBA"

# Bring the cluster up so we can create the role/database/schema.
if ! pg_isready -q -h localhost -p 5432; then
  sudo pg_ctlcluster "$PG_VER" "$PG_CLUSTER" start \
    || sudo pg_ctlcluster "$PG_VER" "$PG_CLUSTER" restart
fi
sudo pg_ctlcluster "$PG_VER" "$PG_CLUSTER" reload >/dev/null 2>&1 || true
for _ in $(seq 1 30); do pg_isready -q -h localhost -p 5432 && break; sleep 1; done

# A login role matching the OS user, and the foodblock database it owns.
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${OS_USER}'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE ROLE \"${OS_USER}\" WITH LOGIN SUPERUSER;"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='foodblock'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE DATABASE foodblock OWNER \"${OS_USER}\";"

# Load the schema only once: schema.sql creates indexes/triggers without
# IF NOT EXISTS, so a second run would error.
if [ "$(psql -tAqc "SELECT to_regclass('public.foodblocks') IS NOT NULL" \
        "postgresql://localhost:5432/foodblock")" != "t" ]; then
  psql "postgresql://localhost:5432/foodblock" -f sql/schema.sql
fi

echo "[install] Done."
