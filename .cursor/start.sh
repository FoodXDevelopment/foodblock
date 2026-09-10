#!/usr/bin/env bash
# Cloud Agent start — per-boot runtime initialization.
#
# Ensures the local PostgreSQL cluster used by the reference-server tests is
# running. Dependency installation and schema creation live in install.sh; this
# script only reconciles the per-boot process state and returns once ready.
set -euo pipefail

PG_VER="$(pg_lsclusters 2>/dev/null | awk 'NR==2{print $1}')"; : "${PG_VER:=16}"
PG_CLUSTER="$(pg_lsclusters 2>/dev/null | awk 'NR==2{print $2}')"; : "${PG_CLUSTER:=main}"

if ! pg_isready -q -h localhost -p 5432; then
  sudo pg_ctlcluster "$PG_VER" "$PG_CLUSTER" start
fi

for _ in $(seq 1 30); do
  if pg_isready -q -h localhost -p 5432; then
    echo "[start] PostgreSQL ${PG_VER}/${PG_CLUSTER} ready on :5432."
    exit 0
  fi
  sleep 1
done

echo "[start] PostgreSQL did not become ready on :5432." >&2
exit 1
