# Fedora on the 12" MacBook (MacBook8,1, Early 2015)

Notes, fixes and links for running Fedora on the 12-inch MacBook (A1534, MacBook8,1).

The new contribution here is a **fix for S3 (deep) suspend**, which normally
leaves the keyboard and trackpad dead after resume. With it, the MacBook can
use S3 instead of the more power-hungry s2idle. The other parts mostly point
to existing projects, plus small Fedora-specific fixes.

| Area | Status on this machine | Where |
|---|---|---|
| Keyboard / trackpad | ✅ works (in-kernel `applespi`, DMA workaround) | [fedora-notes](fedora-notes/README.md) |
| **S3 suspend: keyboard after resume** | ✅ fixed by a sleep hook (new) | [s3-keyboard-fix](s3-keyboard-fix/README.md) |
| Internal speakers | ✅ via [thomas-shirley/macbook8.1-speaker-driver](https://github.com/thomas-shirley/macbook8.1-speaker-driver) | [audio](audio/README.md) |
| Speakers after resume (Fedora) | ✅ fixed by a small patch to the above (new) | [audio](audio/README.md) |
| Bluetooth | ✅ needs a one-line DSDT override; S3 recovery via the same hook + `iomem=relaxed` (new) | [fedora-notes](fedora-notes/README.md), [s3-keyboard-fix](s3-keyboard-fix/README.md) |
| FaceTime HD camera | ✅ via [patjak/facetimehd](https://github.com/patjak/facetimehd) | [fedora-notes](fedora-notes/README.md) |

**Tested on:** one MacBook8,1, Fedora 45, kernel 7.2.15, GNOME.

**S3 testing so far:** the live fix on a broken system, many `rtcwake` S3 cycles,
and real lid-closed suspends of up to **31 hours** (2026-11-04 to 11-07). Keyboard,
trackpad and speakers came back automatically every time. With the current version
(including the Bluetooth part), Bluetooth did too: 4 of 4 resumes, no timeouts.

**Battery drain in S3** (UPower, battery at 84 % of design capacity):

| Suspend | Measured | Drain |
|---|---|---|
| s2idle, for comparison (skyostil in [#49](https://github.com/cb22/macbook12-spi-driver/issues/49)) | n/a | about 1.9 %/h |
| S3, first overnight test | 63.8 % → 58.7 % in 9 h 27 min | about 0.5 %/h |
| S3, two suspends of 6 h 52 min + 31 h 16 min (awake ~1 min in between) | 70.7 % → 59.8 % in about 38 h | **about 0.3 %/h** |

That is roughly 2 weeks of standby from a full battery, compared with about 2 days with s2idle.
The 38-hour figure is approximate: UPower recorded no data points during that
period, so it uses the last value before and the current value after.

## Quick start: S3 fix

```bash
git clone https://github.com/tvpittner/macbook8-1-fedora.git
cd macbook8-1-fedora/s3-keyboard-fix
sudo ./install.sh                     # installs the systemd-sleep hook
echo deep | sudo tee /sys/power/mem_sleep && systemctl suspend   # try once
journalctl -t mb81-spi-sleep -b       # after resume: should end with "applespi OK"
sudo ./install.sh --make-deep-default # if it worked: make S3 the default
```

Keep an external keyboard or SSH at hand for the first try. If anything goes
wrong, the hook falls back to s2idle for the next sleep, and `sudo ./uninstall.sh`
reverts everything.

## Help wanted

This has been tested on **one** machine. Reports from other MacBook8,1 owners
are very welcome, and so is anyone running it on other Broadwell-era Macs with
SPI keyboards. Please open an issue with:

- model (`cat /sys/class/dmi/id/product_name`), distribution, kernel version
- whether S3 + keyboard works with the hook
- the output of `journalctl -t mb81-spi-sleep -b`

The S3 fix should eventually go into the kernel (`spi-pxa2xx-pci` restoring the
LPSS private clock/reset registers on resume). If you have experience
upstreaming to linux-spi / linux-input, help is very welcome.

## Credits

This repository builds on the work of others:

- **Ronald Tschalär**: the `applespi` keyboard/trackpad driver (mainline since 5.3),
  developed in [macbook12-spi-driver](https://github.com/cb22/macbook12-spi-driver)
  (started by cb22) and [roadrunner2/macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver).
- **Thomas Shirley**: the internal speaker driver,
  [thomas-shirley/macbook8.1-speaker-driver](https://github.com/thomas-shirley/macbook8.1-speaker-driver),
  and **Jon Neuneker** for the kernel 7.2.4 fix in the
  [omnidecker fork](https://github.com/omnidecker/macbook8.1-speaker-driver) used here.
  **sjhx** for the related resume-race fix ([PR #6](https://github.com/thomas-shirley/macbook8.1-speaker-driver/pull/6)).
- Everyone in [cb22/macbook12-spi-driver#49](https://github.com/cb22/macbook12-spi-driver/issues/49)
  (open since 2017): especially **roadrunner2** and **andy-shev**, whose debugging
  showed that the SPI controller stops completing transfers / raising interrupts after
  resume, and **skyostil** for the s2idle workaround and battery measurements
  (about 1.1 %/h in S3 vs. 1.9 %/h in s2idle on a MacBook8,1).
- **Patrik Jakobsson and contributors**: [facetimehd](https://github.com/patjak/facetimehd)
  and [facetimehd-firmware](https://github.com/patjak/facetimehd-firmware).
- **Shih-Yuan Lee**: kernel patches forcing PIO mode for SPI on MacBook8,1
  ([1](https://lkml.iu.edu/2607.1/07987.html), [2](https://lkml.iu.edu/2607.1/09178.html)).
- **coreboot**: its Lynx Point / Broadwell SerialIO code documents the LPSS private
  clock/reset registers that the S3 fix relies on
  ([1](https://www.coreboot.org/pipermail/coreboot-gerrit/2013-November/004224.html),
  [2](https://doxygen.coreboot.org/da/d74/broadwell_2include_2soc_2serialio_8h_source.html)).

If something here duplicates or should credit earlier work, please open an
issue and it will be fixed.

## How this was made

The analysis, the scripts and this documentation were produced in sessions with
**Claude** (Anthropic's AI model, via Claude Code) on the actual machine. The
model read the kernel logs, the ACPI tables (DSDT) and the hardware registers
and wrote the fixes, and the owner tested each step on the hardware. Every
claim marked as measured comes from that machine. Anything not measured yet is
marked as such. Please treat this as well-tested-on-one-machine, not as
authoritative.

## License

Scripts and documentation in this repository: GPL-2.0-or-later (see [LICENSE](LICENSE)).
Linked projects have their own licenses.
