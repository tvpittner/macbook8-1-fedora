# S3 (deep) suspend: keyboard and trackpad dead after resume

## Symptom

On the 12" MacBook (MacBook8,1, Early 2015) with `mem_sleep` set to `deep` (S3),
the internal keyboard and trackpad do not work after resume. The kernel log fills
with:

```
applespi spi-APP000D:00: SPI transfer timed out
applespi spi-APP000D:00: Error reading from device: -110
spi_master spi1: failed to transfer one message from queue
```

Reloading `applespi` / `spi_pxa2xx_pci`, or removing the PCI device and rescanning,
does **not** help. Only a reboot does. With `s2idle` the problem does not
occur, which is why many setups use `mem_sleep_default=s2idle`. But s2idle uses
noticeably more battery while suspended.

## Root cause

The keyboard/trackpad sits on the Intel LPSS GSPI controller
(`8086:9ce6`, Wildcat Point-LP Serial IO GSPI #1, usually `0000:00:15.4`,
driver `spi-pxa2xx-pci`). Besides the normal SSP registers, this controller has a
block of **private LPSS registers** at `BAR0 + 0x800`:

| Offset | Register   | After cold boot (measured) | After S3 resume (measured) |
|--------|------------|----------------------------|----------------------------|
| 0x800  | PRV_CLOCK  | `0x80190005` | `0x00000000`: clock gated |
| 0x804  | PRV_RESETS | `0x00000003` | `0x00000000`: held in reset |

The cold-boot `PRV_CLOCK` value decodes to: bit 0 = clock enable, bits 1–15
M = 2, bits 16–30 N = 25 (an M/N divider of the LPSS input clock), bit 31 = update
(latch M/N). So on a cold boot the firmware takes the controller out of reset
and programs the clock, including its divider. On S3 resume it does not. Presumably macOS's own driver handles this,
and Linux doesn't. In PCI mode `spi-pxa2xx-pci` never touches these registers,
so after S3 the controller has no clock and stays in reset. It raises no
interrupts at all (the IRQ counter in `/proc/interrupts` stays frozen), and
every SPI transfer times out.

Things that were checked and are **not** the cause:

- **Keyboard power.** ACPI `_PTS` drops GPIO 13 (`SIEN`), but `applespi`
  re-enables it. After resume GPIO 13 reads as output high.
- **SPI pin muxing.** GPIO 87–90 (the GSPI CS/CLK/MOSI/MISO pins, see the
  `ISOL` method in the DSDT) are still in native mode after resume.
- **PCI power state.** The device is in D0 and memory decode is enabled.

The fix puts back exactly what the firmware programmed at boot: deassert reset
(`0x804 = 0x3`) and restore the saved `PRV_CLOCK` value. coreboot initialises
these controllers the same way on Lynx Point / Broadwell in PCI mode. See
[coreboot: "lynxpoint: Enable SerialIO clock in PCI mode"](https://www.coreboot.org/pipermail/coreboot-gerrit/2013-November/004224.html)
and the register definitions in coreboot's
[Broadwell `serialio.h`](https://doxygen.coreboot.org/da/d74/broadwell_2include_2soc_2serialio_8h_source.html).

**Prior work:** the problem has been tracked since 2017 in
[cb22/macbook12-spi-driver#49](https://github.com/cb22/macbook12-spi-driver/issues/49).
There, roadrunner2 and andy-shev found that after resume the SPI core queues
messages but the controller never completes them, possibly because no interrupt
arrives. Unloading and reloading modules or calling the ACPI `SIEN` method did not
help. The workaround so far was to use s2idle. In that thread and elsewhere we
found no report of the missing LPSS clock/reset state as the cause. If you
know of one, please open an issue so we can credit it.

## The fix

[`mb81-spi-sleep`](mb81-spi-sleep) is a `systemd-sleep` hook. It only acts on
MacBook8,1 and only when deep sleep is used.

- **pre:** unload `applespi`, unbind the GSPI controller from `pxa2xx_spi_pci`,
  save its private register block `0x800`–`0x820` (incl. the firmware's
  `PRV_CLOCK`) to `/run`
- **post:** re-enable PCI memory decode, deassert reset, restore the saved block,
  clock last (if nothing was saved: only set the clock enable bit), bind
  the driver again, load `applespi`, then check the log. If transfers still time
  out, it switches `/sys/power/mem_sleep` back to `s2idle` until the next
  reboot, so the next suspend can't make things worse.

The driver has to be unbound while the registers are written: while it is
bound, the BAR is claimed exclusively and `resource0` cannot be mmapped
(`EINVAL`).

## Bluetooth after S3

The LPSS UART (`8086:9ce3`, `00:15.5`) that carries Bluetooth has the same
problem, and it is nastier. After S3 its whole private block (`0x800`–`0x820`) is
zero:

| Offset | Cold boot | After S3 |
|--------|-----------|----------|
| 0x800 CLOCK | `80190031` | `00000000` |
| 0x804 RESETS | `00000003` | `00000000`: `hci0: command 0x0c01 tx timeout` |
| 0x820 TX_INT | `00000002` (bit 1 = `TX_INT_MASK`) | `00000000` |

Releasing only the reset (an earlier version of this hook) brings Bluetooth back,
but leaves `TX_INT_MASK` cleared. The LPSS then raises an extra TX interrupt that
neither `serial8250_interrupt` nor `ssp_int` claims. IRQ 21 is shared by the UART
and the keyboard's SPI controller, so under Bluetooth audio streaming the kernel
logs `irq 21: nobody cared ... Disabling IRQ #21`, and **Bluetooth and the
internal keyboard/trackpad die together**. The machine looks frozen.

Linux's own ACPI-mode LPSS driver saves and restores exactly this register block
across suspend (`drivers/acpi/acpi_lpss.c`, `LPSS_SAVE_CTX`, `LPSS_TX_INT_MASK`).
In PCI mode nothing does. The hook now does the same for both the SPI and the
UART controller: it **saves `0x800`–`0x820` before sleep and restores it after
resume** (reset first, clock last).

The keyboard approach (unbind, write, rebind) does **not** work for the UART:
after unbinding `8250_lpss` the kernel does not re-create the serdev Bluetooth
device (the ACPI child `BCM2E7C` is left without a physical node) until the next
reboot. So the hook accesses the UART's registers while `8250_lpss` stays bound.
The kernel only allows that with the boot parameter **`iomem=relaxed`**, which lets
root map MMIO regions that drivers have claimed. Without it, the Bluetooth part of
the hook is skipped and only the keyboard is fixed.

Sequence: **pre:** save the UART block, unbind `hci_uart_bcm` from `serial0-0` (the
serdev device stays). **post:** restore the UART block, bind `hci_uart_bcm` again,
which re-initialises the chip.

Security note: `iomem=relaxed` weakens a protection that only matters against root.
On a machine without Secure Boot / kernel lockdown, root can load kernel modules
anyway, so the practical difference is small. Decide for yourself.

Tested: an `rtcwake` S3 cycle, then 3 minutes of A2DP (AAC) streaming to AirPods
Pro. About 60,000 IRQ-21 interrupts, all handled (`/proc/irq/21/spurious`:
`unhandled 0`), with no Bluetooth timeouts. With the reset-only version, the same
scenario disabled IRQ 21. Note that `irqbalance` may move IRQ 21 between CPUs, so
sum all columns of `/proc/interrupts` when you check it.

## Install

```bash
git clone https://github.com/tvpittner/macbook8-1-fedora.git
cd macbook8-1-fedora/s3-keyboard-fix
sudo ./install.sh                       # hook only; your sleep mode is unchanged
# try it once (have an external keyboard or SSH at hand the first time):
echo deep | sudo tee /sys/power/mem_sleep
systemctl suspend
# after resume:
journalctl -t mb81-spi-sleep -b
```

The log should look like this:

```
mb81-spi-sleep: pre: unloading applespi, unbinding 0000:00:15.4
mb81-spi-sleep: lpss save 0000:00:15.4: 80190005 00000003 00000000 00000000 00000800 00000800 00000003 00000000 00000000
mb81-spi-sleep: lpss save 0000:00:15.5: 80190031 00000003 ...                 # UART, only with iomem=relaxed
mb81-spi-sleep: lpss restore 0000:00:15.4: 00000000 00000000 ... -> 80190005 00000003 ...
mb81-spi-sleep: lpss restore 0000:00:15.5: 00000000 00000000 ... -> 80190031 00000003 ... 00000002
mb81-spi-sleep: post: Bluetooth serial0-0 re-bound
mb81-spi-sleep: post: applespi OK
```

If that works, make S3 the default:

```bash
sudo ./install.sh --make-deep-default   # sets mem_sleep_default=deep via grubby
sudo ./install.sh --bluetooth           # adds iomem=relaxed (needed for Bluetooth after S3), reboot afterwards
```

To undo everything: `sudo ./uninstall.sh` (goes back to `s2idle`).

**Requirements:** `python3`, `setpci` (pciutils), `grubby` (Fedora default).
Other distributions: copy the hook to `/usr/lib/systemd/system-sleep/` and set
`mem_sleep_default=deep` with your bootloader's tooling.

## Recovering by hand

If you are stuck with a dead keyboard after S3 without the hook (e.g. using an
external keyboard or SSH), the same steps fix it live, without a reboot. This
writes the cold-boot clock value measured on this MacBook8,1:

```bash
sudo modprobe -r applespi
echo 0000:00:15.4 | sudo tee /sys/bus/pci/drivers/pxa2xx_spi_pci/unbind
sudo setpci -s 00:15.4 COMMAND.w=0006
sudo python3 - <<'PY'
import mmap, os, struct
f = os.open("/sys/bus/pci/devices/0000:00:15.4/resource0", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(f, 4096)
struct.pack_into('<I', m, 0x804, 0); struct.pack_into('<I', m, 0x804, 3)
struct.pack_into('<I', m, 0x800, 0x80190005)
PY
echo 0000:00:15.4 | sudo tee /sys/bus/pci/drivers/pxa2xx_spi_pci/bind
sudo modprobe applespi
```

## Status and limitations

- Tested on **one** MacBook8,1 running Fedora 45, kernel 7.2.15, with the DMA
  workaround from [`../fedora-notes`](../fedora-notes/README.md) (SPI runs in
  PIO mode).
- Verified: the live fix on a broken system, several `rtcwake` S3 cycles, a
  1-hour and a 9.5-hour (overnight) lid-closed suspend. Overnight drain was
  about 0.5 %/h. Those runs used an earlier version that only set the clock
  enable bit (`0x800 = 0x1`, no divider), which also worked. The current
  version restores the exact boot value and has passed an `rtcwake` S3 cycle.
- Once, closing the lid caused a wake-up after ~10 s. logind put the machine
  back to sleep right away because the lid was still closed. The wake source
  is unknown.
- The LPSS UART (`00:15.5`) and I2C (`00:15.2`) controllers likely lose the same
  state. The UART driver (`8250_lpss`) reprograms its own clock. Nothing on this
  machine needs I2C1 in daily use, so they are left alone.
- A proper fix belongs in the kernel: `spi-pxa2xx-pci` (or a quirk) should
  restore `PRV_CLOCK`/`PRV_RESETS` on resume for LPT/WPT controllers in PCI
  mode. This hook is a stopgap. Help with upstreaming is very welcome.
