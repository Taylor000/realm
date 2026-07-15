#!/bin/bash
# Runtime wrapper for Realm.
# It reads /etc/nat.conf, renders Realm TOML, and restarts Realm when rules change.

set -u

REALM_BIN="${REALM_BIN:-/root/realm/realm}"
RULES_FILE="${REALM_RULES_FILE:-/etc/nat.conf}"
REALM_CONFIG_FILE="${REALM_CONFIG_FILE:-/root/.realm/config.toml}"
CHECK_INTERVAL="${REALM_CHECK_INTERVAL:-2}"

child_pid=""

trim() {
    local value=$1
    value=${value//$'\r'/}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

config_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$RULES_FILE" 2>/dev/null | awk '{print $1}'
    else
        cksum "$RULES_FILE" 2>/dev/null | awk '{print $1 ":" $2}'
    fi
}

render_config() {
    mkdir -p "$(dirname "$REALM_CONFIG_FILE")"

    tmp_file="${REALM_CONFIG_FILE}.tmp"
    cat > "$tmp_file" <<'EOF'
[network]
no_tcp = false
use_udp = true

EOF

    if [ ! -f "$RULES_FILE" ]; then
        mv "$tmp_file" "$REALM_CONFIG_FILE"
        return 0
    fi

    line_no=0
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line_no=$((line_no + 1))
        line=$(trim "$raw_line")
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac

        local_port=${line%%:*}
        rest=${line#*:}
        remote_port=${rest##*:}
        remote_host=${rest%:*}

        local_port=$(trim "$local_port")
        remote_host=$(trim "$remote_host")
        remote_port=$(trim "$remote_port")

        if [ "$rest" = "$line" ] || [ "$remote_host" = "$rest" ] || \
            ! valid_port "$local_port" || ! valid_port "$remote_port" || [ -z "$remote_host" ]; then
            echo "WARN: ignored invalid rule at ${RULES_FILE}:${line_no}: $raw_line" >&2
            continue
        fi

        cat >> "$tmp_file" <<EOF
[[endpoints]]
listen = "[::]:${local_port}"
remote = "${remote_host}:${remote_port}"

EOF
    done < "$RULES_FILE"

    mv "$tmp_file" "$REALM_CONFIG_FILE"
}

start_realm() {
    if [ ! -x "$REALM_BIN" ]; then
        echo "ERROR: Realm binary not found: $REALM_BIN" >&2
        exit 1
    fi

    "$REALM_BIN" -c "$REALM_CONFIG_FILE" &
    child_pid=$!
    echo "Realm started with pid ${child_pid}"
}

stop_realm() {
    if [ -n "$child_pid" ] && kill -0 "$child_pid" >/dev/null 2>&1; then
        kill "$child_pid" >/dev/null 2>&1 || true
        wait "$child_pid" 2>/dev/null || true
    fi
    child_pid=""
}

reload_realm() {
    echo "Realm rules changed, reloading..."
    render_config
    stop_realm
    start_realm
}

cleanup() {
    stop_realm
    exit 0
}

trap cleanup INT TERM

render_config
last_hash=$(config_hash)
start_realm

while true; do
    sleep "$CHECK_INTERVAL"

    if [ -n "$child_pid" ] && ! kill -0 "$child_pid" >/dev/null 2>&1; then
        wait "$child_pid" 2>/dev/null || true
        echo "Realm exited, runner will exit and let service manager restart it." >&2
        exit 1
    fi

    current_hash=$(config_hash)
    if [ "$current_hash" != "$last_hash" ]; then
        last_hash="$current_hash"
        reload_realm
    fi
done
