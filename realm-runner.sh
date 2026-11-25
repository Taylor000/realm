#!/bin/bash
# Watch the shared rules and run Realm; --check validates and renders only.
set -uo pipefail
REALM_BIN="${REALM_BIN:-/root/realm/realm}"
RULES_FILE="${REALM_RULES_FILE:-/etc/nat.conf}"
REALM_CONFIG_FILE="${REALM_CONFIG_FILE:-/root/.realm/config.toml}"
CHECK_INTERVAL="${REALM_CHECK_INTERVAL:-2}"
child_pid=""

trim() {
    local value=${1//$'\r'/}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

canonical_port() {
    local value=$1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    while [[ "$value" == 0* && ${#value} -gt 1 ]]; do value=${value#0}; done
    [ "${#value}" -le 5 ] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || return 1
    printf '%d' "$((10#$value))"
}

valid_ipv6() {
    local address=${1%%%*} suffix group compressed=0 count=0
    local -a groups=()
    [[ "$address" != *:::* && ( "$address" != :* || "$address" == ::* ) && ( "$address" != *: || "$address" == *:: ) ]] || return 1
    if [[ "$address" == *.* ]]; then
        suffix=${address##*:}
        IFS=. read -r -a groups <<< "$suffix"
        [ "${#groups[@]}" -eq 4 ] || return 1
        for group in "${groups[@]}"; do
            [[ "$group" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$group))" -le 255 ] || return 1
        done
        address="${address%:*}:0:0"
    fi
    if [[ "$address" == *::* ]]; then
        compressed=1
        suffix=${address#*::}
        [[ "$suffix" != *::* ]] || return 1
    fi
    IFS=: read -r -a groups <<< "$address"
    for group in "${groups[@]}"; do
        [ -n "$group" ] || continue
        [[ "$group" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        count=$((count+1))
    done
    if [ "$compressed" -eq 1 ]; then [ "$count" -lt 8 ]; else [ "$count" -eq 8 ]; fi
}

config_hash() {
    if [ -f "$RULES_FILE" ]; then sha256sum "$RULES_FILE" | awk '{print $1}'; else echo missing; fi
}

render_config() {
    local tmp line raw_line rest local_port remote_port remote_host host line_no=0
    local -A seen=()
    mkdir -p "$(dirname "$REALM_CONFIG_FILE")" || return 1
    tmp=$(mktemp "${REALM_CONFIG_FILE}.XXXXXX") || return 1
    printf '[network]\nno_tcp = false\nuse_udp = true\n\n' > "$tmp" || { rm -f "$tmp"; return 1; }
    if [ -f "$RULES_FILE" ]; then
        while IFS= read -r raw_line || [ -n "$raw_line" ]; do
            line_no=$((line_no+1))
            line=$(trim "$raw_line")
            case "$line" in ''|\#*) continue ;; esac
            local_port=$(trim "${line%%:*}")
            rest=${line#*:}
            remote_port=$(trim "${rest##*:}")
            remote_host=$(trim "${rest%:*}")
            if [ "$rest" == "$line" ] || [ "$remote_host" == "$rest" ] ||
                ! local_port=$(canonical_port "$local_port") || ! remote_port=$(canonical_port "$remote_port") ||
                [ -n "${seen[$local_port]:-}" ]; then
                echo "ERROR: invalid, unsupported or duplicate rule at $RULES_FILE:$line_no: $raw_line" >&2
                rm -f "$tmp"; return 1
            fi
            if [[ "$remote_host" == \[*\] ]]; then
                host=${remote_host:1:${#remote_host}-2}
                [[ "$host" == *:* && "$host" =~ ^[0-9a-fA-F:.]+(%[a-zA-Z0-9_.-]+)?$ ]] && valid_ipv6 "$host" || host=""
            elif [[ "$remote_host" == *:* ]]; then
                host=$remote_host
                [[ "$host" =~ ^[0-9a-fA-F:.]+(%[a-zA-Z0-9_.-]+)?$ ]] && valid_ipv6 "$host" || host=""
                remote_host="[$host]"
            elif [[ "$remote_host" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]]; then
                host=$remote_host
            else
                host=""
            fi
            if [ -z "$host" ]; then
                echo "ERROR: invalid remote address at $RULES_FILE:$line_no: $raw_line" >&2
                rm -f "$tmp"; return 1
            fi
            seen[$local_port]=1
            printf '[[endpoints]]\nlisten = "[::]:%s"\nremote = "%s:%s"\n\n' "$local_port" "$remote_host" "$remote_port" >> "$tmp" || { rm -f "$tmp"; return 1; }
        done < "$RULES_FILE"
    fi
    mv -f "$tmp" "$REALM_CONFIG_FILE"
}

start_realm() {
    if ! grep -q '^\[\[endpoints\]\]' "$REALM_CONFIG_FILE"; then
        echo "No forwarding rules; waiting for changes to $RULES_FILE."
        child_pid=""
        return 0
    fi
    [ -x "$REALM_BIN" ] || { echo "ERROR: Realm binary not found: $REALM_BIN" >&2; return 1; }
    "$REALM_BIN" -c "$REALM_CONFIG_FILE" &
    child_pid=$!
    local check
    # Keep the previous config until the replacement has survived startup.
    for ((check=0; check<5; check++)); do
        sleep 1
        if ! kill -0 "$child_pid" 2>/dev/null; then
            wait "$child_pid" 2>/dev/null || true
            child_pid=""
            echo "ERROR: Realm exited during startup." >&2
            return 1
        fi
    done
    echo "Realm started with pid $child_pid"
}

stop_realm() {
    if [ -n "$child_pid" ]; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    child_pid=""
}

reload_realm() {
    local backup
    backup=$(mktemp "${REALM_CONFIG_FILE}.previous.XXXXXX") || return 1
    cp -p "$REALM_CONFIG_FILE" "$backup" || { rm -f "$backup"; return 1; }
    if ! render_config; then
        echo "Rules rejected; keeping the previous Realm configuration and process." >&2
        rm -f "$backup"
        return 0
    fi
    stop_realm
    if ! start_realm; then
        echo "New rules failed to start; restoring the previous Realm configuration." >&2
        mv -f "$backup" "$REALM_CONFIG_FILE" || return 1
        start_realm || return 1
    else
        rm -f "$backup"
    fi
}

cleanup() {
    trap - INT TERM
    stop_realm
    exit 0
}

main() {
    if [ "${1:-}" == --check ]; then render_config; return $?; fi
    if [ "$#" -ne 0 ]; then echo "Usage: $0 [--check]" >&2; return 1; fi
    trap cleanup INT TERM
    local last_hash current_hash
    last_hash=$(config_hash) || return 1
    render_config || return 1
    start_realm || return 1
    while true; do
        sleep "$CHECK_INTERVAL"
        if [ -n "$child_pid" ] && ! kill -0 "$child_pid" 2>/dev/null; then
            wait "$child_pid" 2>/dev/null || true
            echo "Realm exited; exiting the runner for systemd recovery." >&2
            return 1
        fi
        current_hash=$(config_hash) || continue
        if [ "$current_hash" != "$last_hash" ]; then
            last_hash=$current_hash
            reload_realm || { stop_realm; return 1; }
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
