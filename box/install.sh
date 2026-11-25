#!/bin/sh
# Install SyncBox on Raspberry Pi OS (Lite): mpv, the player, and a service that starts it on power-up.
# Run on the box: sudo sh install.sh
set -eu
[ "$(id -u)" = 0 ] || { echo "sudo sh install.sh で実行してください"; exit 1; }
USER_NAME="${SUDO_USER:-pi}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
HERE="$(cd "$(dirname "$0")" && pwd)"

apt-get update
apt-get install -y mpv python3

install -d /opt/syncbox
install -m 755 "$HERE/syncbox.py" /opt/syncbox/syncbox.py
install -d -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/syncbox"
if [ ! -f "$HOME_DIR/syncbox/syncbox.json" ]; then
    install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$HERE/syncbox.example.json" "$HOME_DIR/syncbox/syncbox.json"
fi
sed -e "s#@USER@#$USER_NAME#g" -e "s#@HOME@#$HOME_DIR#g" "$HERE/syncbox.service" > /etc/systemd/system/syncbox.service
systemctl daemon-reload
systemctl enable syncbox.service
echo "入れました。$HOME_DIR/syncbox/ に映像を置き、syncbox.json の movie を直してから: sudo systemctl restart syncbox"
