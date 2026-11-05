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

## Bluetooth: required DSDT override

Bluetooth is a Broadcom BCM4350C0 on the LPSS UART (`00:15.5`, ACPI
`\_SB.PCI0.URT0.BLTH`, driver `hci_uart_bcm`). Out of the box, every boot logs
`serial serial0-0: failure adding ACPI serdev device. status -EBUSY` and **there is
no Bluetooth controller**. The UART has a second ACPI child,
`\_SB.PCI0.URT0.SSDC` (`apple-uart-ssdc`), and serdev only supports one device per
port. So the Bluetooth device never gets created.

This machine uses a DSDT override that changes `SSDC`'s `_STA` from `0x0F` to
`Zero` (one line). Then `hci0` appears. It is loaded via dracut:

```
# /etc/dracut.conf.d/macbook81-acpi.conf
acpi_override="yes"
acpi_table_dir="/etc/dracut-acpi"
```

*(An earlier version of this page called the override "cosmetic". That was
wrong: without it there is no Bluetooth. We verified this in the boot logs from before and after the override.)*

No modified firmware table is distributed here. To do it yourself: dump with `acpidump`,
disassemble with `iasl -d`, change that one `_STA`, bump the OEM revision,
recompile, and put the `.aml` in `/etc/dracut-acpi/` (then `sudo dracut -f`). See the
[kernel docs on initrd table override](https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html).

**Messages that look bad but are harmless** (Bluetooth works with them):

- `BCM: failed to write update baudrate (-16)` / `Failed to set baudrate`: on Apple
  machines `hci_bcm` takes the ACPI `_DSM` property `"baud"` (3,000,000) as the
  initial speed and opens the UART at 3 Mbaud right away. The chip then rejects
  the redundant "switch to 3 Mbaud" command ("Command Disallowed" = `-EBUSY`).
  All later HCI commands succeed, so the link runs at 3 Mbaud.
- `BCM: firmware Patch file not found, tried: 'brcm/BCM.hcd'`: no Apple patch RAM
  file is available, so the chip runs its ROM firmware. Basic use works without
  it.

**After S3 suspend** Bluetooth stops working (`hci0: command 0x0c01 tx timeout`).
The UART loses its LPSS reset state just like the keyboard's SPI controller. See
[`../s3-keyboard-fix`](../s3-keyboard-fix/README.md), which also fixes this when
booted with `iomem=relaxed`.
