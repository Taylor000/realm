#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REALM_TESTING=1 source "$PROJECT_ROOT/realm.sh"

assert_eq() {
    local expected=$1
    local actual=$2
    local name=$3
    if [[ "$actual" != "$expected" ]]; then
        echo "${name}: expected '${expected}', got '${actual}'" >&2
        exit 1
    fi
}

assert_eq "openrc" "$(REALM_INIT_SYSTEM=openrc detect_init_system)" "detect openrc override"
assert_eq "systemd" "$(REALM_INIT_SYSTEM=systemd detect_init_system)" "detect systemd override"
assert_eq "apk" "$(REALM_PACKAGE_MANAGER=apk detect_package_manager)" "detect apk override"
assert_eq "realm-x86_64-unknown-linux-musl.tar.gz" "$(REALM_LIBC=musl select_realm_filename x86_64)" "select x86_64 musl"
assert_eq "realm-aarch64-unknown-linux-musl.tar.gz" "$(REALM_LIBC=musl select_realm_filename aarch64)" "select aarch64 musl"
assert_eq "realm-x86_64-unknown-linux-gnu.tar.gz" "$(REALM_LIBC=gnu select_realm_filename x86_64)" "select x86_64 gnu"

if REALM_LIBC=musl select_realm_filename riscv64 >/dev/null; then
    echo "unsupported architecture should fail" >&2
    exit 1
fi
