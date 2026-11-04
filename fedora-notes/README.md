# Fedora setup notes for the MacBook8,1

This page records how the rest of this machine is set up. Most of it is existing
work by other people, collected here with links.

## Keyboard and trackpad at boot (incl. the LUKS password prompt)

The keyboard/trackpad driver is `applespi`, by Ronald Tschalär. It has been in the
mainline kernel since 5.3. It was developed out of tree in
[macbook12-spi-driver](https://github.com/cb22/macbook12-spi-driver), started by cb22,
with development continued in [roadrunner2/macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver).
That README also describes the initramfs requirement below.

**DMA timeouts.** On MacBook8,1 the DMA path between the DesignWare DMA controller
(`dw_dmac`) and `spi-pxa2xx-pci` makes SPI transfers time out, so the keyboard
doesn't work. Shih-Yuan Lee has posted kernel patches that force PIO mode on this
model:
[applespi: force PIO mode on MacBook8,1](https://lkml.iu.edu/2607.1/07987.html),
[spi: pxa2xx: disable DMA and fix runtime PM for Apple MacBook8,1](https://lkml.iu.edu/2607.1/09178.html).
Until a kernel with those patches is available, this machine keeps the
DMA driver from loading:

```
# kernel command line
modprobe.blacklist=dw_dmac_pci initcall_blacklist=dw_pci_driver_init
```

```
# /etc/modprobe.d/macbook81-spi.conf
blacklist dw_dmac_pci
```

The log then shows `pxa2xx_spi_pci 0000:00:15.4: no DMA channels available, using PIO`.

**Early loading for LUKS.** To type the disk encryption password, the drivers
must be in the initramfs:

```
# /etc/dracut.conf.d/macbook81.conf
add_drivers+=" applespi spi_pxa2xx_platform spi_pxa2xx_pci intel_lpss_pci "
omit_drivers+=" dw_dmac_pci "
```

Then run `sudo dracut -f --regenerate-all`.

## Suspend

See [`../s3-keyboard-fix`](../s3-keyboard-fix/README.md). Without that hook,
use `mem_sleep_default=s2idle`. With it, `mem_sleep_default=deep` works.

## Speakers

See [`../audio`](../audio/README.md), which points to
[thomas-shirley/macbook8.1-speaker-driver](https://github.com/thomas-shirley/macbook8.1-speaker-driver).

## FaceTime HD camera

Uses the [facetimehd](https://github.com/patjak/facetimehd) driver by Patrik
Jakobsson and contributors (DKMS), plus the firmware extracted with
[facetimehd-firmware](https://github.com/patjak/facetimehd-firmware). See the
[project wiki](https://github.com/patjak/facetimehd/wiki) for Fedora instructions.
As recommended there:

```
# /etc/modprobe.d/facetimehd.conf
blacklist bdc_pci
```

## Optional, cosmetic: silence the `serdev -EBUSY` boot message

Every boot logs `serial serial0-0: failure adding ACPI serdev device. status -EBUSY`.
It comes from the ACPI device `\_SB.PCI0.URT0.SSDC` (`apple-uart-ssdc`) on the LPSS
UART. This machine uses a DSDT override that changes that device's `_STA` from
`0x0F` to `Zero` (one line), loaded via dracut:

```
# /etc/dracut.conf.d/macbook81-acpi.conf
acpi_override="yes"
acpi_table_dir="/etc/dracut-acpi"
```

This only removes the message. No functional effect has been observed, so
it isn't recommended unless the message bothers you. No modified firmware
table is distributed here. To do it yourself: dump with `acpidump`,
disassemble with `iasl -d`, change that one `_STA`, bump the OEM revision,
recompile, and put the `.aml` in `/etc/dracut-acpi/`. See the
[kernel docs on initrd table override](https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html).
