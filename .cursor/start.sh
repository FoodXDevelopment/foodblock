#!/usr/bin/env bash
# Per-boot startup: bring PostgreSQL up and confirm the dev/test databases
# and schema exist. The reference server (terminals) auto-applies the schema
# to the dev DB, but the test DB (TEST=1) needs it preloaded.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PG_VERSION=16
PG_CLUSTER=main

echo "==> Start PostgreSQL cluster"
sudo pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" start 2>/dev/null || true
for i in $(seq 1 20); do
  if sudo -u postgres pg_isready -q; then break; fi
  sleep 1
done

echo "==> Ensure databases + schema"
for db in foodblock foodblock_test; do
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE $db OWNER ubuntu;"
  fi
  if ! psql "postgresql://localhost:5432/$db" -tAc "SELECT to_regclass('public.foodblocks')" | grep -q foodblocks; then
    psql "postgresql://localhost:5432/$db" -v ON_ERROR_STOP=1 -f sql/schema.sql
  fi
done

echo "==> start.sh complete — PostgreSQL ready on localhost:5432"
