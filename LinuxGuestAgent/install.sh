#!/bin/sh
# Installs the Hypervisaur agent, which runs programs in this virtual machine for Hypervisaur on the Mac.
# Run it with: sudo sh install.sh

set -eu

if [ "$(id -u)" -ne 0 ]; then
    exec sudo sh "$0" "$@"
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "The Hypervisaur agent needs Python 3. Install it with your package manager, such as \"sudo apt install python3\", then run this again." >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "The Hypervisaur agent runs as a systemd service, and this system doesn't use systemd." >&2
    exit 1
fi

directory=$(dirname "$0")
install -m 0755 "$directory/hypervisaur-agent" /usr/local/sbin/hypervisaur-agent
install -m 0644 "$directory/hypervisaur-agent.service" /etc/systemd/system/hypervisaur-agent.service

systemctl daemon-reload
systemctl enable hypervisaur-agent.service
systemctl restart hypervisaur-agent.service

echo "The Hypervisaur agent is installed. Hypervisaur can now run programs in this virtual machine."
