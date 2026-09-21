#!/bin/bash -p
# Privileged-mode bash ignores inherited startup code before this file is read.
set -euo pipefail
export PATH=/usr/bin:/bin
unset BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME PYTHONUSERBASE
script_dir="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
exec /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I "$script_dir/queue-controller.py" "$@"
