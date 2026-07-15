#!/bin/bash
# One-command installer for self-hosted Realm forwarding.

set -e

REPO="Taylor000/realm"
BRANCH="${BRANCH:-main}"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

REALM_DIR="/root/realm"
REALM_BIN="${REALM_DIR}/realm"
RULES_FILE="/etc/nat.conf"
REALM_CONFIG_DIR="/root/.realm"
REALM_CONFIG_FILE="${REALM_CONFIG_DIR}/config.toml"
RUNNER_PATH="/usr/local/bin/realm-runner"
SERVICE_FILE="/etc/systemd/system/realm.service"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_musl_system() {
    [ -f /etc/alpine-release ] || { command_exists ldd && ldd --version 2>&1 | grep -qi musl; }
}

select_realm_filename() {
    arch=$(uname -m)
    libc="gnu"
    is_musl_system && libc="musl"

    case "$arch" in
        x86_64|amd64) echo "realm-x86_64-unknown-linux-${libc}.tar.gz" ;;
        aarch64|arm64) echo "realm-aarch64-unknown-linux-${libc}.tar.gz" ;;
        *)
            echo "Unsupported architecture: $arch" >&2
            return 1
            ;;
    esac
}

install_dependencies() {
    echo "Preparing system dependencies..."
    if command_exists apt-get; then
        apt-get update
        apt-get install -y curl wget tar ca-certificates coreutils
    elif command_exists yum; then
        yum install -y curl wget tar ca-certificates coreutils
    elif command_exists apk; then
        apk add --no-cache bash curl wget tar ca-certificates coreutils
        update-ca-certificates || true
    else
        echo "Unsupported package manager. Please install curl, wget, tar and coreutils manually."
        exit 1
    fi

    if ! command_exists systemctl; then
        echo "systemd is required by this installer."
        exit 1
    fi
}

latest_realm_version() {
    curl -fsSL https://api.github.com/repos/zhboner/realm/releases/latest |
        grep '"tag_name":' |
        sed -E 's/.*"([^"]+)".*/\1/' |
        head -1
}

install_realm_binary() {
    mkdir -p "$REALM_DIR"

    version=$(latest_realm_version || true)
    [ -z "$version" ] && version="v2.6.0"
    filename=$(select_realm_filename)
    url="https://github.com/zhboner/realm/releases/download/${version}/${filename}"

    echo "Downloading Realm ${version}..."
    curl -fL "$url" -o /tmp/realm.tar.gz
    tar -xzf /tmp/realm.tar.gz -C "$REALM_DIR"
    rm -f /tmp/realm.tar.gz
    chmod +x "$REALM_BIN"
}

install_runner() {
    echo "Installing realm runner..."
    curl -fsSL "${RAW_BASE_URL}/realm-runner.sh" -o "$RUNNER_PATH"
    chmod 755 "$RUNNER_PATH"
}

write_default_rules() {
    if [ ! -s "$RULES_FILE" ]; then
        cat > "$RULES_FILE" <<'EOF'
# Realm forwarding rules. This file is shared with the nft project.
# Format: local_port:remote_ip_or_domain:remote_port
# Example:
# 33351:node.example.com:33344
# IPv6 remote addresses should use brackets:
# 33352:[2001:db8::1]:33344

EOF
    fi

    mkdir -p "$REALM_CONFIG_DIR"
}

write_service() {
    echo "Creating systemd service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=REALM_BIN=${REALM_BIN}
Environment=REALM_RULES_FILE=${RULES_FILE}
Environment=REALM_CONFIG_FILE=${REALM_CONFIG_FILE}
ExecStart=${RUNNER_PATH}
Restart=always
RestartSec=5
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm
    systemctl restart realm
}

install_dependencies
install_realm_binary
install_runner
write_default_rules
write_service

echo ""
echo "Realm installed and started."
echo "Rules file: ${RULES_FILE}"
echo "Generated config: ${REALM_CONFIG_FILE}"
echo ""
echo "Edit ${RULES_FILE} with rules like:"
echo "33351:node.example.com:33344"
echo ""
echo "After saving the rules file, realm.service will reload automatically."
echo "Status: systemctl status realm"
echo "Logs:   journalctl -fu realm"
