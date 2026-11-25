#!/bin/bash
# The installer owns preflight, backup, health checks and rollback.
set -Eeuo pipefail
REPO="Taylor000/realm"
export BRANCH="${BRANCH:-main}"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
[ "$(id -u)" -eq 0 ] || { echo "Please run as root" >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -r "$script_dir/setup.sh" ] && [ -r "$script_dir/backend-common.sh" ]; then
    exec bash "$script_dir/setup.sh"
fi
work_dir=$(mktemp -d /tmp/switch-to-realm.XXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT
installer_pid=""
interrupt_install() {
    local status=$1
    trap - INT TERM
    if [ -n "$installer_pid" ]; then
        # Async Bash children can inherit SIGINT ignored; TERM always reaches setup.
        kill -TERM "$installer_pid" 2>/dev/null || true
        wait "$installer_pid" || true
    fi
    exit "$status"
}
trap 'interrupt_install 130' INT
trap 'interrupt_install 143' TERM
curl --connect-timeout 15 --max-time 180 --retry 2 -fsSL "${RAW_BASE_URL}/setup.sh" -o "$work_dir/setup.sh"
bash -n "$work_dir/setup.sh"
bash "$work_dir/setup.sh" &
installer_pid=$!
wait "$installer_pid"
