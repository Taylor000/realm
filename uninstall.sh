#!/bin/bash
# Uninstall Realm service and files while keeping the shared /etc/nat.conf by default.

set -e

RULES_FILE="/etc/nat.conf"
REALM_DIR="/root/realm"
REALM_CONFIG_DIR="/root/.realm"
RUNNER_PATH="/usr/local/bin/realm-runner"
SERVICE_FILE="/etc/systemd/system/realm.service"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo "Stopping and disabling realm.service..."
systemctl stop realm 2>/dev/null || true
systemctl disable realm 2>/dev/null || true

echo "Removing Realm service and program files..."
rm -f "$SERVICE_FILE"
rm -f "$RUNNER_PATH"
rm -rf "$REALM_DIR"
rm -rf "$REALM_CONFIG_DIR"

systemctl daemon-reload
systemctl reset-failed realm 2>/dev/null || true

if [ "${REMOVE_REALM_RULES:-0}" = "1" ]; then
    rm -f "$RULES_FILE"
    echo "Rules file removed: ${RULES_FILE}"
else
    echo "Rules file kept: ${RULES_FILE}"
    echo "Run with REMOVE_REALM_RULES=1 if you also want to remove it."
fi

echo "Realm service has been uninstalled."
