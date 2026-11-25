#!/bin/bash
# Kept identical in nftables-nat-rust and Realm. No side effects when sourced.

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_packages() {
    [ "$#" -gt 0 ] || return 0
    if command_exists apt-get; then
        if ! apt-get update || ! apt-get install -y "$@"; then
            echo "Dependency installation failed. Repair the APT sources reported above (including retired backports/security mirrors), then retry. Existing forwarding has not been stopped." >&2
            return 1
        fi
    elif command_exists yum; then
        yum install -y "$@"
    elif command_exists apk; then
        apk add --no-cache "$@"
    else
        echo "Install the missing packages manually: $*" >&2
        return 1
    fi
}

download() {
    curl --connect-timeout 15 --max-time 180 --retry 2 -fsSL "$1" -o "$2"
}

snapshot_owned_tables() {
    : > "$BACKUP_DIR/owned-tables.nft"
    command_exists nft || return 0
    local tables family table
    tables=$(nft list tables) || { echo "Cannot inspect nftables; existing forwarding is unchanged." >&2; return 1; }
    for family in ip ip6; do
        for table in self-nat self-filter; do
            if grep -qx "table $family $table" <<< "$tables"; then
                nft -n list table "$family" "$table" >> "$BACKUP_DIR/owned-tables.nft" || return 1
            fi
        done
    done
}

remove_owned_tables() {
    command_exists nft || return 0
    local tables family table
    tables=$(nft list tables) || return 1
    for family in ip ip6; do
        for table in self-nat self-filter; do
            if grep -qx "table $family $table" <<< "$tables"; then
                nft delete table "$family" "$table" || return 1
            fi
        done
    done
}

begin_switch() {
    TARGET_SERVICE=$1
    PREVIOUS_SERVICE=$2
    SWITCH_STARTED=0
    SWITCH_COMMITTED=0
    FILES_CHANGED=0
    SNAPSHOT_PATHS=()
    mkdir -p "$(dirname "${FORWARD_LOCK_FILE:-/run/lock/forward-backend.lock}")"
    exec {SWITCH_LOCK_FD}> "${FORWARD_LOCK_FILE:-/run/lock/forward-backend.lock}"
    if ! flock -n "$SWITCH_LOCK_FD"; then
        echo "Another forwarding backend switch is in progress." >&2
        return 1
    fi
    local state
    state=$(systemctl is-enabled "$TARGET_SERVICE" 2>/dev/null || true)
    if [[ "$state" == masked* ]]; then
        echo "$TARGET_SERVICE is masked; unmask it before switching." >&2
        return 1
    fi
    TARGET_ENABLED=$state
    PREVIOUS_ENABLED=$(systemctl is-enabled "$PREVIOUS_SERVICE" 2>/dev/null || true)
    TARGET_ACTIVE=0
    PREVIOUS_ACTIVE=0
    systemctl is-active --quiet "$TARGET_SERVICE" && TARGET_ACTIVE=1
    systemctl is-active --quiet "$PREVIOUS_SERVICE" && PREVIOUS_ACTIVE=1
    if [[ "$PREVIOUS_ENABLED" == masked* ]] && [ "$PREVIOUS_ACTIVE" -eq 1 ]; then
        echo "The running $PREVIOUS_SERVICE is masked and cannot be restarted on failure. Unmask it before switching." >&2
        return 1
    fi
    for state in "$TARGET_ENABLED" "$PREVIOUS_ENABLED"; do
        case "$state" in
            enabled|enabled-runtime|disabled|static|not-found|masked|masked-runtime|"") ;;
            *) echo "Unsupported service enablement state: $state. Resolve linked/custom units before switching." >&2; return 1 ;;
        esac
    done
    mkdir -p "${BACKUP_BASE:-/var/backups}"
    BACKUP_DIR=$(mktemp -d "${BACKUP_BASE:-/var/backups}/forward-switch.XXXXXX")
    printf 'target=%s active=%s enabled=%s\nprevious=%s active=%s enabled=%s\n' \
        "$TARGET_SERVICE" "$TARGET_ACTIVE" "$TARGET_ENABLED" \
        "$PREVIOUS_SERVICE" "$PREVIOUS_ACTIVE" "$PREVIOUS_ENABLED" > "$BACKUP_DIR/services.txt"
    echo "Switch backup: $BACKUP_DIR"
    snapshot_owned_tables
    TRANSACTION_ACTIVE=1
}

snapshot_file() {
    local path=$1 index=${#SNAPSHOT_PATHS[@]}
    if [ -e "$path" ] || [ -L "$path" ]; then
        cp -a "$path" "$BACKUP_DIR/file.$index"
    else
        : > "$BACKUP_DIR/file.$index.missing"
    fi
    # Publish only complete records; snapshotting itself never changes live files.
    SNAPSHOT_PATHS+=("$path")
    printf '%s\t%s\n' "$index" "$path" >> "$BACKUP_DIR/files.txt"
}

atomic_install() {
    local source=$1 dest=$2 mode=${3:-755}
    mkdir -p "$(dirname "$dest")"
    install -m "$mode" "$source" "$dest.new.$$"
    FILES_CHANGED=1
    mv -f "$dest.new.$$" "$dest"
}

restore_enabled() {
    local service=$1 state=$2
    case "$state" in
        enabled) systemctl enable "$service" ;;
        enabled-runtime) systemctl enable --runtime "$service" ;;
        disabled|static) systemctl disable "$service" ;;
        not-found|"") return 0 ;;
        *) return 0 ;;
    esac
}

rollback_switch() {
    echo "Restoring previous forwarding backend and files from $BACKUP_DIR..." >&2
    local failed=0 i path
    if [ "$(systemctl show "$TARGET_SERVICE" --property=LoadState --value)" != not-found ]; then
        systemctl stop "$TARGET_SERVICE" || failed=1
    fi
    # Remove newly added persistent links while the new unit file still exists.
    if [ "$SWITCH_STARTED" -eq 1 ]; then systemctl disable "$TARGET_SERVICE" || failed=1; fi
    for ((i=${#SNAPSHOT_PATHS[@]}-1; i>=0; i--)); do
        path=${SNAPSHOT_PATHS[i]}
        if [ -e "$BACKUP_DIR/file.$i" ] || [ -L "$BACKUP_DIR/file.$i" ]; then
            cp -a "$BACKUP_DIR/file.$i" "$path.restore.$$" && mv -Tf "$path.restore.$$" "$path" || failed=1
        elif [ -f "$BACKUP_DIR/file.$i.missing" ]; then
            rm -f "$path" || failed=1
        else
            echo "ERROR: missing file snapshot for $path" >&2
            failed=1
        fi
    done
    systemctl daemon-reload || failed=1
    if [ "$SWITCH_STARTED" -eq 1 ]; then
        restore_enabled "$TARGET_SERVICE" "$TARGET_ENABLED" || failed=1
        restore_enabled "$PREVIOUS_SERVICE" "$PREVIOUS_ENABLED" || failed=1
    fi
    if [ "$SWITCH_STARTED" -eq 1 ]; then
        remove_owned_tables || failed=1
        if ! { [ "$TARGET_SERVICE" == nat ] && [ "$TARGET_ACTIVE" -eq 1 ]; } &&
            ! { [ "$PREVIOUS_SERVICE" == nat ] && [ "$PREVIOUS_ACTIVE" -eq 1 ]; } &&
            [ -s "$BACKUP_DIR/owned-tables.nft" ]; then
            nft -f "$BACKUP_DIR/owned-tables.nft" || failed=1
        fi
    fi
    if [ "$TARGET_ACTIVE" -eq 1 ]; then
        systemctl start "$TARGET_SERVICE" || failed=1
    fi
    if [ "$PREVIOUS_ACTIVE" -eq 1 ]; then
        if [ "$PREVIOUS_SERVICE" == nat ] && [ "$SWITCH_STARTED" -eq 1 ]; then
            systemctl restart "$PREVIOUS_SERVICE" || failed=1
        elif ! systemctl is-active --quiet "$PREVIOUS_SERVICE"; then
            systemctl start "$PREVIOUS_SERVICE" || failed=1
        fi
    fi
    if [ "$failed" -ne 0 ]; then
        echo "ERROR: automatic rollback was incomplete. Backups and service states: $BACKUP_DIR" >&2
    fi
    return "$failed"
}

finish_install() {
    local status=$1
    trap - EXIT INT TERM
    if [ "${TRANSACTION_ACTIVE:-0}" -eq 1 ] && [ "${SWITCH_COMMITTED:-0}" -ne 1 ]; then
        [ "$status" -ne 0 ] || status=1
        if [ "${FILES_CHANGED:-0}" -eq 1 ] || [ "${SWITCH_STARTED:-0}" -eq 1 ]; then
            rollback_switch || status=1
        fi
    fi
    if [ -n "${WORK_DIR:-}" ]; then rm -rf -- "$WORK_DIR"; fi
    exit "$status"
}

activate_backend() {
    local ready_function=$1 load_state pid restarts current_pid current_restarts stable=0 attempt
    SWITCH_STARTED=1
    load_state=$(systemctl show "$PREVIOUS_SERVICE" --property=LoadState --value)
    if [ "$load_state" != not-found ]; then
        systemctl stop "$PREVIOUS_SERVICE"
        systemctl disable "$PREVIOUS_SERVICE"
    fi
    # Backend-specific cleanup occurs after stopping the previous service.
    if declare -F before_backend_start >/dev/null; then before_backend_start; fi
    systemctl daemon-reload
    systemctl enable "$TARGET_SERVICE"
    systemctl restart "$TARGET_SERVICE"
    pid=""
    restarts=$(systemctl show "$TARGET_SERVICE" --property=NRestarts --value)
    for ((attempt=0; attempt<20; attempt++)); do
        current_pid=$(systemctl show "$TARGET_SERVICE" --property=MainPID --value)
        current_restarts=$(systemctl show "$TARGET_SERVICE" --property=NRestarts --value)
        if [ "$current_restarts" != "$restarts" ]; then break; fi
        if systemctl is-active --quiet "$TARGET_SERVICE" && [ "$current_pid" != 0 ] && [ -n "$current_pid" ] && "$ready_function"; then
            if [ "$pid" == "$current_pid" ]; then stable=$((stable+1)); else stable=1; fi
            pid=$current_pid
            if [ "$stable" -ge 5 ]; then return 0; fi
        else
            stable=0
        fi
        sleep 1
    done
    echo "ERROR: $TARGET_SERVICE did not become healthy; rolling back." >&2
    journalctl -u "$TARGET_SERVICE" -n 25 --no-pager >&2 || true
    return 1
}

commit_switch() {
    if systemctl is-active --quiet "$PREVIOUS_SERVICE"; then
        echo "ERROR: both forwarding backends are active." >&2
        return 1
    fi
    SWITCH_COMMITTED=1
}
