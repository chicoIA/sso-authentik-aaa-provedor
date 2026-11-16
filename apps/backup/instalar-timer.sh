#!/usr/bin/env bash
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/systemd"
install -m 644 "$D/provedor-backup.service" "$D/provedor-backup.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now provedor-backup.timer
systemctl list-timers provedor-backup.timer --no-pager
