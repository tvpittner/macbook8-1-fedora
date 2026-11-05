# Internal speakers (CS4208): use the existing driver project

The speaker driver is **not** part of this repository. It is the work of
Thomas Shirley:

**➜ [thomas-shirley/macbook8.1-speaker-driver](https://github.com/thomas-shirley/macbook8.1-speaker-driver)**

This machine uses Jon Neuneker's fork
[omnidecker/macbook8.1-speaker-driver](https://github.com/omnidecker/macbook8.1-speaker-driver),
which adds a fix for kernel 7.2.4 (commit `e4134fb`). On Fedora 45 (kernel 7.2.15)
it builds and works with DKMS as-is. Install it by following its README.

## Fedora-specific issue: speakers silent after every resume

The project ships `resume_recover.sh` and `mb81-resume-recover.service`, which
re-heal the codec after suspend. To do that, the script stops PipeWire and the
jack-switch monitor, unloads `snd_hda_intel` and runs `efi_recover.py`.

On Fedora this failed on **every** resume (s2idle and S3 alike), with:

```
FAIL: 00:1b.0 still bound after unload
Something still holds the module. Reboot to recover.
```

**Cause:** Fedora runs `alsa-state.service`, a root `alsactl rdaemon` that keeps
`/dev/snd/controlC*` open permanently. Ubuntu and Arch normally use the oneshot
`alsa-restore.service` instead, which is probably why the upstream authors
didn't hit this. The open control device pins the module, so
`modprobe -r snd_hda_intel` can never succeed. The script hid the error because
of a `2>/dev/null`.

You can confirm it with `sudo fuser -v /dev/snd/*`. On an affected system,
`alsactl` (root) shows up holding `controlC1`.

A related upstream PR,
[#6 "Wait for ALSA users before resume recovery unload"](https://github.com/thomas-shirley/macbook8.1-speaker-driver/pull/6)
by sjhx, fixes a *race* with the same symptom on Ubuntu: it waits up to 5 s for
the devices to be released. On Fedora, `alsactl rdaemon` never releases them, so
the wait alone is not enough. Both fixes complement each other.

**Fix:** [`fedora-alsa-state.patch`](fedora-alsa-state.patch) stops
`alsa-state.service` before unloading, restarts it from an `EXIT` trap (so it
also comes back when the script fails), and stops suppressing the unload error.

```bash
cd macbook8.1-speaker-driver
patch -p1 < /path/to/macbook8-1-fedora/audio/fedora-alsa-state.patch
# then re-run the project's install, or copy resume_recover.sh to where your
# mb81-resume-recover.service points (here: /usr/local/bin/mb81-resume-recover)
```

With the patch, the recovery script ran to completion here for the first time
and the speakers played afterwards.

This patch is offered upstream as well. Once it is merged there, this
section will only point to the upstream project.

## Bluetooth headphones stay the default output after resume

Two places in the upstream scripts hard-wire the internal speaker as the default
sink. With Bluetooth headphones (e.g. AirPods) that means after every resume the
sound comes out of the speaker:

- `resume_recover.sh` step 5 runs `pactl set-default-sink input.MacBook_Speaker`.
- `mb81-jack-switch.sh` sets the speaker as default at every (re)start when no
  wired headphones are plugged in, and the resume script restarts it.

Both overwrite WirePlumber's remembered preference
(`~/.local/state/wireplumber/default-nodes`). If that still names the Bluetooth
device, WirePlumber switches back to it by itself as soon as it reconnects.

[`keep-bluetooth-default.patch`](keep-bluetooth-default.patch) leaves the default
alone when the preferred sink is a `bluez_*` device and no wired headphones are
plugged in. Wired-headphone switching is unchanged. Apply it after
`fedora-alsa-state.patch`:

```bash
cd macbook8.1-speaker-driver
patch -p1 < /path/to/macbook8-1-fedora/audio/fedora-alsa-state.patch
patch -p1 < /path/to/macbook8-1-fedora/audio/keep-bluetooth-default.patch
```

Combined with the Bluetooth part of [`../s3-keyboard-fix`](../s3-keyboard-fix/README.md)
(which reconnects previously connected Bluetooth devices after resume), AirPods
come back as the active output about 30 s after opening the lid. Tested with an
S3 cycle.
