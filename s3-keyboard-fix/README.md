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

| Offset | Register   | After S3 resume (measured) | After the fix (measured, keyboard works) |
|--------|------------|----------------------------|------------------------------------------|
| 0x800  | PRV_CLOCK  | `0x00000000`: clock gated | `0x00000001` |
| 0x804  | PRV_RESETS | `0x00000000`: held in reset | `0x00000003` |

The values right after a cold boot have not been dumped yet (that requires
briefly unbinding the driver on a freshly booted machine). They will be added
here. Since the keyboard works after a cold boot, the firmware evidently brings
the controller out of reset and enables its clock there. On S3 resume it does
not. Presumably macOS's own driver handles this,
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

The fix uses the same sequence that coreboot uses for these controllers on
Lynx Point / Broadwell in PCI mode: deassert reset (`0x804 = 0x3`) and set the
clock enable bit (`0x800 |= 1`). See
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

- **pre:** unload `applespi`, unbind the GSPI controller from `pxa2xx_spi_pci`
- **post:** re-enable PCI memory decode, write the two private registers, bind
  the driver again, load `applespi`, then check the log. If transfers still time
  out, it switches `/sys/power/mem_sleep` back to `s2idle` until the next
  reboot, so the next suspend can't make things worse.

The driver has to be unbound while the registers are written: while it is
bound, the BAR is claimed exclusively and `resource0` cannot be mmapped
(`EINVAL`).

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
mb81-spi-sleep: lpss init: clk 0x00000000->0x00000001 rst 0x00000000->0x00000003
mb81-spi-sleep: post: applespi OK
```

If that works, make S3 the default:

```bash
sudo ./install.sh --make-deep-default   # sets mem_sleep_default=deep via grubby
```

To undo everything: `sudo ./uninstall.sh` (goes back to `s2idle`).

**Requirements:** `python3`, `setpci` (pciutils), `grubby` (Fedora default).
Other distributions: copy the hook to `/usr/lib/systemd/system-sleep/` and set
`mem_sleep_default=deep` with your bootloader's tooling.

## Recovering by hand

If you are stuck with a dead keyboard after S3 without the hook (e.g. using an
external keyboard or SSH), the same steps fix it live, without a reboot:

```bash
sudo modprobe -r applespi
echo 0000:00:15.4 | sudo tee /sys/bus/pci/drivers/pxa2xx_spi_pci/unbind
sudo setpci -s 00:15.4 COMMAND.w=0006
sudo python3 - <<'PY'
import mmap, os, struct
f = os.open("/sys/bus/pci/devices/0000:00:15.4/resource0", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(f, 4096)
struct.pack_into('<I', m, 0x804, 0); struct.pack_into('<I', m, 0x804, 3)
struct.pack_into('<I', m, 0x800, struct.unpack_from('<I', m, 0x800)[0] | 1)
PY
echo 0000:00:15.4 | sudo tee /sys/bus/pci/drivers/pxa2xx_spi_pci/bind
sudo modprobe applespi
```

## Status and limitations

- Tested on **one** MacBook8,1 running Fedora 45, kernel 7.2.15, with the DMA
  workaround from [`../fedora-notes`](../fedora-notes/README.md) (SPI runs in
  PIO mode).
- Verified: the live fix on a broken system, and a short `rtcwake` S3 cycle.
  Longer real-world use (a full night with the lid closed) is
  documented in the main README's status table.
- The LPSS UART (`00:15.5`) and I2C (`00:15.2`) controllers likely lose the same
  state. The UART driver (`8250_lpss`) reprograms its own clock. Nothing on this
  machine needs I2C1 in daily use, so they are left alone.
- A proper fix belongs in the kernel: `spi-pxa2xx-pci` (or a quirk) should
  restore `PRV_CLOCK`/`PRV_RESETS` on resume for LPT/WPT controllers in PCI
  mode. This hook is a stopgap. Help with upstreaming is very welcome.
