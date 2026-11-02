#!/usr/bin/env bash
# Installs (or upgrades) plesk-s3-backup on this server.
#
#   git clone https://github.com/DRodero/plesk-s3-backup.git /opt/plesk-s3-backup
#   /opt/plesk-s3-backup/install.sh
#
# It is safe to run again after `git pull`: the configuration is never
# overwritten and the timer is not enabled until you do it yourself.
#
#   install.sh --uninstall   removes the systemd units (keeps config, logs
#                            and local copies)

set -euo pipefail

INSTALL_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
CONF_DIR=/etc/plesk-s3-backup
UNIT_DIR=/etc/systemd/system
NAME=plesk-s3-backup

[[ $(id -u) == 0 ]] || { echo "Run as root" >&2; exit 1; }
command -v systemctl > /dev/null || { echo "systemd not found: see README for cron" >&2; exit 1; }

if [[ ${1:-} == --uninstall ]]; then
    systemctl disable --now "$NAME.timer" 2> /dev/null || true
    rm -f "$UNIT_DIR/$NAME.service" "$UNIT_DIR/$NAME.timer" /usr/local/sbin/$NAME
    systemctl daemon-reload
    echo "Removed. Configuration ($CONF_DIR), logs and local copies were kept."
    exit 0
fi

echo "Installing from $INSTALL_DIR"

# Dependencies
missing=()
for cmd in s3cmd mysql mysqldump tar gzip flock; do
    command -v "$cmd" > /dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    echo "WARNING: missing commands: ${missing[*]}"
    echo "         (s3cmd: apt install s3cmd  /  dnf install s3cmd)"
fi

chmod 755 "$INSTALL_DIR/backup.sh"
ln -sfn "$INSTALL_DIR/backup.sh" /usr/local/sbin/$NAME

# Configuration (never overwritten)
install -d -m 700 "$CONF_DIR"
if [[ ! -f $CONF_DIR/backup.conf ]]; then
    install -m 600 "$INSTALL_DIR/backup.conf.example" "$CONF_DIR/backup.conf"
    echo "Created $CONF_DIR/backup.conf"
    new_config=yes
else
    chmod 600 "$CONF_DIR/backup.conf"
    echo "Keeping existing $CONF_DIR/backup.conf"
    new_config=no
fi

# Data directories
install -d -m 700 /var/lib/$NAME /var/backups/$NAME
install -d -m 750 /var/log/$NAME

# systemd units
for unit in "$NAME.service" "$NAME.timer"; do
    sed "s#@INSTALL_DIR@#$INSTALL_DIR#g" "$INSTALL_DIR/systemd/$unit" > "$UNIT_DIR/$unit"
    chmod 644 "$UNIT_DIR/$unit"
done
systemctl daemon-reload

echo
if systemctl is-enabled --quiet "$NAME.timer" 2> /dev/null; then
    echo "Upgrade done. The daily timer is enabled:"
    systemctl list-timers "$NAME.timer" --no-pager || true
else
    echo "Next steps:"
    [[ $new_config == yes ]] && echo "  - Edit the configuration:    $CONF_DIR/backup.conf"
    cat << EOF
  - Check everything:          $NAME check
  - See what rotation would do: $NAME list
  - First manual run:          systemctl start $NAME.service && journalctl -u $NAME -f
  - Enable the daily timer:    systemctl enable --now $NAME.timer
EOF
fi
