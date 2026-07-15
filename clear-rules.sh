#!/bin/bash
# Clear active Realm rules while keeping the shared /etc/nat.conf rules file.

set -e

RULES_FILE="/etc/nat.conf"
REALM_CONFIG_FILE="/root/.realm/config.toml"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

mkdir -p "$(dirname "$REALM_CONFIG_FILE")"

systemctl stop realm 2>/dev/null || true

cat > "$REALM_CONFIG_FILE" <<'EOF'
[network]
no_tcp = false
use_udp = true

EOF

echo "Realm active rules cleared."
echo "Rules file kept: ${RULES_FILE}"
echo "Generated config reset: ${REALM_CONFIG_FILE}"
echo "realm.service has been stopped. Start it again to apply ${RULES_FILE}."
