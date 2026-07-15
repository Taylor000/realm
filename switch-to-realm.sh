#!/bin/bash
# Switch forwarding backend from nftables-nat-rust to Realm.
# The shared rules file /etc/nat.conf is always kept.

set -e

REPO="Taylor000/realm"
BRANCH="${BRANCH:-main}"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
RULES_FILE="/etc/nat.conf"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

if [ -f "$RULES_FILE" ]; then
    backup_file="${RULES_FILE}.switch-to-realm.$(date +%Y%m%d%H%M%S).bak"
    cp -p "$RULES_FILE" "$backup_file"
    echo "Rules backup: ${backup_file}"
fi

tmp_setup="/tmp/realm-setup.$$"
curl -fsSL "${RAW_BASE_URL}/setup.sh" -o "$tmp_setup"
bash "$tmp_setup"
rm -f "$tmp_setup"

echo ""
echo "Switched to Realm."
echo "Rules file kept: ${RULES_FILE}"
echo "Current backend: forward-status"
echo "Status: systemctl status realm"
