#!/bin/bash
# Install the MacBook8,1 S3 keyboard/trackpad fix and (optionally) make deep sleep the default.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo ./install.sh [--make-deep-default|--bluetooth]"; exit 1; }
grep -qx "MacBook8,1" /sys/class/dmi/id/product_name || { echo "not a MacBook8,1 - aborting"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
install -m 755 "$HERE/mb81-spi-sleep" /usr/lib/systemd/system-sleep/mb81-spi-sleep
echo "installed /usr/lib/systemd/system-sleep/mb81-spi-sleep"
if [[ "${1:-}" == "--bluetooth" ]]; then
    grubby --update-kernel=ALL --args=iomem=relaxed
    [[ -f /etc/default/grub ]] && ! grep -q "iomem=relaxed" /etc/default/grub && \
        sed -i -E 's/^(GRUB_CMDLINE_LINUX=".*)"/\1 iomem=relaxed"/' /etc/default/grub
    echo "added iomem=relaxed (Bluetooth recovery after S3) - reboot to activate"
elif [[ "${1:-}" == "--make-deep-default" ]]; then
    grubby --update-kernel=ALL --remove-args=mem_sleep_default --args=mem_sleep_default=deep
    [[ -f /etc/default/grub ]] && sed -i -E 's/ ?mem_sleep_default=[a-z0-9]+//; s/^(GRUB_CMDLINE_LINUX=".*)"/\1 mem_sleep_default=deep"/' /etc/default/grub
    echo deep > /sys/power/mem_sleep
    echo "deep (S3) is now the default sleep mode: $(cat /sys/power/mem_sleep)"
else
    echo "to try S3 once:  echo deep | sudo tee /sys/power/mem_sleep && systemctl suspend"
fi
