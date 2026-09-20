#!/usr/bin/env bash
# Durable, shadow-only merge queue. All GitHub access is read-only; --self-test is offline.
# State is an execution journal, not a ticket store. See README.md, Merge queue (shadow).
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$SCRIPT_ROOT/scripts/merge-queue.py" "$@"
