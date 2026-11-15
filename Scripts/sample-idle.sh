#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sampler_dir=$(mktemp -d)
trap 'rm -f "$sampler_dir/sample-idle"; rmdir "$sampler_dir"' EXIT
xcrun clang -O2 -Wall -Wextra sample-idle.c -o "$sampler_dir/sample-idle"
if [[ $# -lt 1 ]]; then
    printf '%s\n' 'Usage: Scripts/sample-idle.sh PID [SECONDS]' >&2
    exit 2
fi
"$sampler_dir/sample-idle" "$1" "${2:-300}"
