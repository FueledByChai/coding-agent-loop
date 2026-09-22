#!/bin/bash -p
# Durable foreground author/acceptance workers; no CI or merge authority.
set -euo pipefail
unset BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME PYTHONUSERBASE
script_dir="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
exec /usr/bin/python3 -I "$script_dir/review-workers.py" "$@"
