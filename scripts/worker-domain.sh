#!/usr/bin/env bash
# Whole-job supervision; production uses a fixed protected privileged entry point.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$SCRIPT_ROOT/scripts/worker-domain.py" "$@"
