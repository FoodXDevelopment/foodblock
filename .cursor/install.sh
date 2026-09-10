#!/usr/bin/env bash
# Idempotent repository bootstrap for the FoodBlock monorepo.
# Installs PostgreSQL + all per-SDK/server dependencies and provisions the
# dev/test databases. Safe to run repeatedly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PG_VERSION=16
PG_CLUSTER=main

echo "==> [1/7] Ensure PostgreSQL is installed"
if ! command -v pg_ctlcluster >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-contrib
fi

echo "==> [2/7] Start PostgreSQL cluster"
sudo pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" start 2>/dev/null || true
for i in $(seq 1 20); do
  if sudo -u postgres pg_isready -q; then break; fi
  sleep 1
done

echo "==> [3/7] Create role + databases"
sudo -u postgres psql -v ON_ERROR_STOP=1 -c \
  "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='ubuntu') THEN CREATE ROLE ubuntu LOGIN SUPERUSER; END IF; END \$\$;"
for db in foodblock foodblock_test; do
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE $db OWNER ubuntu;"
  fi
done

echo "==> [4/7] Enable trust auth for local TCP connections"
HBA="$(sudo -u postgres psql -tAc 'SHOW hba_file;')"
sudo sed -i "s/^host\(.*\)127.0.0.1\/32\(.*\)scram-sha-256/host\1127.0.0.1\/32\2trust/" "$HBA"
sudo sed -i "s/^host\(.*\)::1\/128\(.*\)scram-sha-256/host\1::1\/128\2trust/" "$HBA"
sudo pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" reload 2>/dev/null || true

echo "==> [5/7] Load schema (only when tables are absent)"
for db in foodblock foodblock_test; do
  if ! psql "postgresql://localhost:5432/$db" -tAc "SELECT to_regclass('public.foodblocks')" | grep -q foodblocks; then
    psql "postgresql://localhost:5432/$db" -v ON_ERROR_STOP=1 -f sql/schema.sql
  fi
done

echo "==> [6/7] Install Node dependencies (mcp, server, cli)"
( cd mcp && npm install --install-links )
( cd server && npm install )
( cd cli && npm install )

echo "==> [7/7] Install Python SDK + pytest, download Go modules"
python3 -m pip install --user -e sdk/python
python3 -m pip install --user pytest
( cd sdk/go && go mod download )

echo "==> install.sh complete"
