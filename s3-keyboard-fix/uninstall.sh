#!/bin/bash
# Remove the hook and go back to s2idle.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
rm -f /usr/lib/systemd/system-sleep/mb81-spi-sleep
grubby --update-kernel=ALL --remove-args=mem_sleep_default --args=mem_sleep_default=s2idle
[[ -f /etc/default/grub ]] && sed -i -E 's/mem_sleep_default=deep/mem_sleep_default=s2idle/' /etc/default/grub
echo s2idle > /sys/power/mem_sleep
echo "removed; sleep mode: $(cat /sys/power/mem_sleep)"
