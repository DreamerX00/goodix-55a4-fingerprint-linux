# Goodix 55A4 Fingerprint Driver for Linux (goodix-55a4-fingerprint-linux)

Enable the **Goodix 27C6:55A4** fingerprint sensor (**USB `27c6:55a4`**) on
Linux. One installer for **Ubuntu 26**, **Fedora**, **Arch**, **openSUSE** and
more — build and swap in the community `libfprint` 55A4 driver, provision the
sensor's one-time key, and enroll your fingerprint for login.

## Why is a fix needed?

The stock Goodix driver shipped by distros
(`libfprint-2-tod1-goodix`) only talks to the **550A** chip — a *different,
incompatible protocol*. The **55A4** sensor speaks the *TLS-PSK* variant,
which upstream `libfprint` never implemented. Fedora, Arch and openSUSE ship
no Goodix TLS driver at all. As a result the sensor is detected by USB but
never works.

This repo compiles the patched `libfprint` that *does* read 55A4, installs it
into `/opt/libfprint-goodix`, and points **only** `fprintd.service` at it.
Your distro's own `libfprint` is left untouched, so the fix is fully
reversible.

## Quick start

```bash
sudo bash install.sh          # full install + enable fingerprint login
```

When it finishes, enroll a finger:

```bash
sudo fprintd-enroll    # 16 touches; vary the finger position each time
sudo fprintd-verify     # test it
fprintd-list             # should list "Goodix TLS Fingerprint Sensor 55X4"
```

Options:

```bash
sudo bash install.sh --no-pam   # install driver only (no login/PAM change)
bash install.sh --help          # usage
```

## What the script does

1. Detects your distro and installs build dependencies (apt / dnf / zypper /
   pacman / apk).
2. Builds the patched `libfprint` from
   [Hydrogell/goodix-27c6-55a4-fingerprint-linux](https://github.com/Hydrogell/goodix-27c6-55a4-fingerprint-linux),
   pinned to the exact commits the patch was written against.
3. Installs the resulting library to `/opt/libfprint-goodix/lib64` and adds a
   `fprintd.service` drop-in setting `LD_LIBRARY_PATH`.
4. Installs a suspend/resume guard: a systemd unit
   (`fprintd-sleep-fix.service`) that stops `fprintd` before sleep and
   restarts it on resume, plus a udev rule disabling USB runtime autosuspend
   for the sensor. Without it, suspending mid-verify leaves the device
   claimed by a dead session and every unlock after resume fails with
   *"Device was already claimed"* until a reboot.
5. Provisions the sensor's one-time TLS-PSK key (`goodix-fp-dump` +
   `provision_psk.py`). This is a one-time per-sensor step.
6. Optionally configures PAM so fingerprints unlock at login
   (best-effort per distro).
7. Verifies the device is now visible to `fprintd`.

## Supported distros

| Package manager | Distros | Fingerprint login (PAM) |
|-----------------|---------|--------------------------|
| `apt`   | Debian, Ubuntu, Mint, Pop!_OS, Zorin, Elementary | automatic (`pam-auth-update`) |
| `dnf`/`yum` | Fedora, RHEL, CentOS, Rocky, Alma | automatic (`authconfig --enable-fingerprint`) |
| `pacman` | Arch, Manjaro, EndeavourOS | manual — see below |
| `zypper` | openSUSE, SLES | manual |
| `apk` | Alpine | manual |

Tested most on **Ubuntu 26.04** (this repo was made to get it working there)
and Fedora. Unsupported package managers fail with a clear message.

## Enabling fingerprint at login on Arch / openSUSE

Install an enrollment + PAM stack or add `pam_fprintd.so` to
`/etc/pam.d/system-auth` in the `auth` section:

```
auth       sufficient       pam_fprintd.so
```

The script deliberately does **not** rewrite `/etc/pam.d` on these distros.

## Uninstall / roll back

Everything the installer adds is removed by one command:

```bash
sudo bash uninstall.sh
```

That deletes the patched library in `/opt/libfprint-goodix`, the fprintd
drop-in, the `fprintd-sleep-fix.service` unit and the autosuspend udev rule,
then restarts fprintd on your distro's stock libfprint.

## Troubleshooting

- **Fingerprint stops working until a reboot (worked before suspend):** this
  is the stale-claim bug the installer's suspend/resume guard exists for —
  `journalctl -u fprintd` will show *"Unexpected error while suspending
  device: ... still busy"* at suspend and *"Device was already claimed"* on
  every unlock after resume. Check the guard is in place:
  ```bash
  systemctl is-enabled fprintd-sleep-fix.service   # should print: enabled
  ```
  If it is missing (installed with an older version of this script), re-run
  `sudo bash install.sh` — it is idempotent. A one-off
  `sudo systemctl restart fprintd` revives the reader immediately.
- **`fprintd-list` shows no device:** check the daemon log
  `sudo journalctl -u fprintd.service -b`. The usual cause is the key step
  having been skipped. Re-run provisioning:
  ```bash
  cd /var/tmp/goodix55a4-build/goodix-fp-dump
  sudo PYTHONDONTWRITEBYTECODE=1 .venv/bin/python provision_psk.py
  ```
- **meson fails on a missing `.*.pc` file:** some distros ship `udev`/
  `doctest` headers without the `.pc` pkg-config file meson wants. The script
  auto-injects a minimal `udev.pc` when that happens. If it still fails,
  install the deps manually for your package manager and re-run.
- The build compiles once at install time; it does not run continuously.

## Repository layout

```
install.sh     → the entire fix (build, install, provision, PAM, verify)
uninstall.sh   → one-command rollback
README.md      → this file
LICENSE        → see below
```

## License

- The installer scripts in this repo are **MIT**.
- The *patched library* built at runtime is **LGPL-2.1** (it is
  `libfprint`), plus the driver patch is **GPL-2.0** from the upstream repos
  linked above, and the provisioning tool is **GPL-3.0**.

## Credits

- Patched driver — [Hydrogell/goodix-27c6-55a4-fingerprint-linux](https://github.com/Hydrogell/goodix-27c6-55a4-fingerprint-linux)
- Base lib — [TheWeirdDev/libfprint](https://github.com/TheWeirdDev/libfprint) (`55b4-experimental`)
- Key tool — [goodix-fp-linux-dev/goodix-fp-dump](https://github.com/goodix-fp-linux-dev/goodix-fp-dump)