#!/bin/bash
# Install or switch to Realm while preserving the shared forwarding rules.
set -Eeuo pipefail

REPO="Taylor000/realm"
BRANCH="${BRANCH:-main}"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
REALM_DIR="/root/realm"
REALM_BIN="${REALM_DIR}/realm"
RULES_FILE="/etc/nat.conf"
REALM_CONFIG_DIR="/root/.realm"
REALM_CONFIG_FILE="${REALM_CONFIG_DIR}/config.toml"
RUNNER_PATH="/usr/local/bin/realm-runner"
STATUS_PATH="/usr/local/bin/forward-status"
SERVICE_FILE="/etc/systemd/system/realm.service"

load_common() {
    local script_dir
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    if [ -r "$script_dir/backend-common.sh" ]; then
        source "$script_dir/backend-common.sh"
    else
        curl --connect-timeout 15 --max-time 180 --retry 2 -fsSL "${RAW_BASE_URL}/backend-common.sh" -o "$WORK_DIR/backend-common.sh"
        source "$WORK_DIR/backend-common.sh"
    fi
}

install_dependencies() {
    local packages=()
    command_exists systemctl || { echo "systemd is required by this installer." >&2; return 1; }
    command_exists curl || packages+=(curl)
    command_exists tar || packages+=(tar)
    command_exists sha256sum && command_exists install && command_exists mktemp || packages+=(coreutils)
    command_exists flock || packages+=(util-linux)
    if ! command_exists ss; then
        if command_exists yum; then packages+=(iproute); else packages+=(iproute2); fi
    fi
    [ -s /etc/ssl/certs/ca-certificates.crt ] || packages+=(ca-certificates)
    install_packages "${packages[@]}"
}

is_musl_system() {
    [ -f /etc/alpine-release ] || { command_exists ldd && ldd --version 2>&1 | grep -qi musl; }
}

latest_realm_version() {
    curl --connect-timeout 15 --max-time 30 -fsSL https://api.github.com/repos/zhboner/realm/releases/latest |
        sed -nE 's/.*"tag_name": *"([^"]+)".*/\1/p'
}

install_realm_binary() {
    REALM_STAGED_BINARY="$WORK_DIR/realm"
    if [ -z "${REALM_VERSION:-}" ] && [ -x "$REALM_BIN" ] && "$REALM_BIN" --version >/dev/null 2>&1; then
        cp -p "$REALM_BIN" "$REALM_STAGED_BINARY"
        echo "Reusing the installed Realm binary."
        return
    fi
    local version arch libc filename
    version=${REALM_VERSION:-$(latest_realm_version || true)}
    version=${version:-v2.6.0}
    [[ "$version" =~ ^v[0-9][a-zA-Z0-9._-]*$ ]] || { echo "Invalid Realm version: $version" >&2; return 1; }
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
    local variants=(gnu musl)
    if is_musl_system; then variants=(musl); fi
    for libc in "${variants[@]}"; do
        filename="realm-${arch}-unknown-linux-${libc}.tar.gz"
        mkdir -p "$WORK_DIR/$libc"
        echo "Preparing Realm $version ($libc)..."
        if download "https://github.com/zhboner/realm/releases/download/${version}/${filename}" "$WORK_DIR/realm.tar.gz" &&
            tar -xzf "$WORK_DIR/realm.tar.gz" -C "$WORK_DIR/$libc" &&
            chmod 755 "$WORK_DIR/$libc/realm" &&
            "$WORK_DIR/$libc/realm" --version > "$WORK_DIR/version.log" 2>&1; then
            cp -p "$WORK_DIR/$libc/realm" "$REALM_STAGED_BINARY"
            cat "$WORK_DIR/version.log"
            return 0
        fi
        cat "$WORK_DIR/version.log" >&2 2>/dev/null || true
        echo "Realm $libc build is unavailable or incompatible; trying the next build." >&2
    done
    echo "No runnable Realm binary was found. Existing forwarding is unchanged." >&2
    return 1
}

write_service() {
    cat > "$WORK_DIR/realm.service" <<UNIT
[Unit]
Description=Realm Forwarding Service
After=network-online.target
Wants=network-online.target
Conflicts=nat.service

[Service]
Type=simple
Environment=REALM_BIN=${REALM_BIN}
Environment=REALM_RULES_FILE=${RULES_FILE}
Environment=REALM_CONFIG_FILE=${REALM_CONFIG_FILE}
ExecStart=${RUNNER_PATH}
Restart=on-failure
RestartSec=5
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
UNIT
}

before_backend_start() {
    remove_owned_tables
}

realm_ready() {
    [ -n "$REALM_PORTS" ] || return 0
    local port main_pid children child realm_pid=""
    main_pid=$(systemctl show realm --property=MainPID --value)
    children=$(cat "/proc/$main_pid/task/$main_pid/children" 2>/dev/null) || return 1
    for child in $children; do
        if [ "/proc/$child/exe" -ef "$REALM_BIN" ]; then realm_pid=$child; break; fi
    done
    [ -n "$realm_pid" ] || return 1
    for port in $REALM_PORTS; do
        ss -H -lntp "sport = :$port" | grep -q "pid=$realm_pid," || return 1
        ss -H -lnup "sport = :$port" | grep -q "pid=$realm_pid," || return 1
    done
}

main() {
    [ "$(id -u)" -eq 0 ] || { echo "Please run as root" >&2; return 1; }
    WORK_DIR=$(mktemp -d /tmp/realm-setup.XXXXXX)
    trap 'rm -rf -- "$WORK_DIR"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    load_common
    trap 'finish_install $?' EXIT
    install_dependencies
    systemctl show-environment >/dev/null
    begin_switch realm nat
    if [ "${KEEP_NFT:-0}" == 1 ] && { [ "$PREVIOUS_ACTIVE" -eq 1 ] || [ -s "$BACKUP_DIR/owned-tables.nft" ]; }; then
        echo "KEEP_NFT=1 cannot keep nft forwarding active while switching to Realm. Retry without KEEP_NFT." >&2
        return 1
    fi
    install_realm_binary
    download "${RAW_BASE_URL}/realm-runner.sh" "$WORK_DIR/realm-runner"
    download "${RAW_BASE_URL}/status.sh" "$WORK_DIR/forward-status"
    bash -n "$WORK_DIR/realm-runner"
    bash -n "$WORK_DIR/forward-status"
    local staged_rules=$RULES_FILE
    if [ ! -f "$RULES_FILE" ]; then
        staged_rules="$WORK_DIR/nat.conf"
        printf '# Shared forwarding rules: local_port:remote_host:remote_port\n' > "$staged_rules"
    fi
    REALM_RULES_FILE="$staged_rules" REALM_CONFIG_FILE="$WORK_DIR/config.toml" bash "$WORK_DIR/realm-runner" --check
    REALM_PORTS=$(sed -nE 's/^listen = "\[::\]:([0-9]+)"$/\1/p' "$WORK_DIR/config.toml")
    write_service
    local path
    for path in "$REALM_BIN" "$RUNNER_PATH" "$STATUS_PATH" "$SERVICE_FILE" "$REALM_CONFIG_FILE" "$RULES_FILE"; do snapshot_file "$path"; done
    atomic_install "$REALM_STAGED_BINARY" "$REALM_BIN"
    atomic_install "$WORK_DIR/realm-runner" "$RUNNER_PATH"
    atomic_install "$WORK_DIR/forward-status" "$STATUS_PATH"
    atomic_install "$WORK_DIR/realm.service" "$SERVICE_FILE" 644
    if [ ! -f "$RULES_FILE" ]; then atomic_install "$staged_rules" "$RULES_FILE" 644; fi
    activate_backend realm_ready
    commit_switch
    echo "Switched to Realm. Rules preserved: $RULES_FILE"
    if [ -z "$REALM_PORTS" ]; then echo "No forwarding rules: Realm runner is idle and will reload when rules are added."; fi
    echo "Status: forward-status; journalctl -u realm -f"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
