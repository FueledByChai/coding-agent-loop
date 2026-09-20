#!/usr/bin/env bash
# Durable foreground author/acceptance workers; no CI or merge authority.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$SCRIPT_ROOT/scripts/review-workers.py" "$@"
