#!/usr/bin/env bash
#
# install.sh — enable the Goodix 27c6:55a4 fingerprint sensor on Linux.
#
# The sensor is NOT supported by any packaged driver: distro libfprint's
# Goodix driver only talks to the 550A chip (an incompatible protocol), and
# Fedora/Arch/openSUSE ship no Goodix 55A4 driver at all.
#
# This script builds a community-patched libfprint (Hydrogell's fork of
# TheWeirdDev/libfprint, 55b4-experimental branch, pinned to an exact commit),
# installs it to /opt/libfprint-goodix, points ONLY fprintd.service at it via
# a systemd drop-in, provisions the sensor's one-time TLS key, and runs PAM
# setup for fingerprint login when possible. Your distro's own libfprint is
# untouched, so the whole fix is reversible with a single command.
#
# Supported package managers: apt (Debian/Ubuntu), dnf/yum (Fedora/RHEL),
# zypper (openSUSE), pacman (Arch & friends), apk (Alpine).
#
# Usage:
#   sudo bash install.sh            # full install + PAM
#   sudo bash install.sh --no-pam     # driver only (enrollment still works)
#   bash install.sh --help
#
# Environment override for advanced testing:
#   FIX_REPO_URL=...                  alternate patched driver repo
#
set -uo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------- config ----
FORK_URL="https://github.com/TheWeirdDev/libfprint.git"
FORK_REV="d1ca62a801aa565e67d1a2a47aaa7a33232b7990"
REPO_URL="${FIX_REPO_URL:-https://github.com/Hydrogell/goodix-27c6-55a4-fingerprint-linux.git}"
DUMP_URL="https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git"
DUMP_REV="cc43bb3b3154a0bccc0412ae024013c7e1923139"

BUILD=/var/tmp/goodix55a4-build
SRC="$BUILD/driver-repo"
FORK="$BUILD/libfprint"
DUMP="$BUILD/goodix-fp-dump"
LIBRARY="$FORK/_build/libfprint/libfprint-2.so.2.0.0"
DEST=/opt/libfprint-goodix/lib64
DROPIN=/etc/systemd/system/fprintd.service.d
WORKDIR="$(mktemp -d)" && trap 'rm -rf "$WORKDIR"' EXIT

AUTO_PAM=1
usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [--no-pam|--help]

  --no-pam   install the driver only; do NOT modify login (PAM).
  --help     show this help.

The fix is system-wide, so it must run as root (sudo).
EOF
}
for a in "$@"; do case "$a" in
  --no-pam) AUTO_PAM=0;;
  -h|--help) usage; exit 0;;
  *) :;;
esac; done

# ------------------------------------------------------------ helpers ----
die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Run a labelled step, exiting on failure. e.g.  step "clone" git clone ...
step() {
  echo "== $1 =="; shift
  "$@" || { echo "ERROR: step failed: $*" >&2; exit 1; }
}
# Best-effort: warn and keep going instead of exiting.
step_nf() {
  echo "== $1 (best-effort) =="; shift
  "$@" 2>&1 || warn "step failed: $1 (excluding additional ${*:2:+args})"
}

# --------------------------------------------------- package manager -----
PM=
detect_pm() {
  have apt-get && { PM=apt;   return; }
  have dnf     && { PM=dnf;   return; }
  have zypper  && { PM=zypper; return; }
  have pacman  && { PM=pacman; return; }
  have apk     && { PM=apk;   return; }
  have yum     && { PM=yum;   return; }
  cat /etc/os-release 2>/dev/null >&2
  die "unsupported package manager — open an issue with /etc/os-release"
}

install_deps() {
  case "$PM" in
    apt)
      apt-get update -qq
      apt-get install -y --no-install-recommends \
        git curl build-essential meson ninja-build pkg-config \
        libglib2.0-dev libgusb-dev libnss3-dev libssl-dev libcairo2-dev \
        libgudev-1.0-dev libpixman1-dev libopencv-dev doctest-dev libudev-dev \
        python3 python3-venv
      ;;
    dnf|yum)
      "$PM" install -y \
        git curl cmake meson ninja-build gcc gcc-c++ pkgconfig \
        libgusb-devel nss-devel openssl-devel cairo-devel glib2-devel libgudev1-devel \
        pixman-devel opencv-devel doctest-devel libudev-devel python3 python3-venv
      ;;
    zypper)
      zypper --non-interactive install \
        git curl cmake meson ninja gcc gcc-c++ pkgconfig \
        libgusb-devel mozilla-nss-devel libopenssl-devel cairo-devel glib2-devel \
        libgudev-1_0-devel pixman-devel opencv-devel doctest-devel python3 python3-venv
      ;;
    pacman)
      pacman -Sy --needed --noconfirm \
        git curl base-devel meson ninja gcc pkg-config glib2 libgusb nss openssl \
        cairo pixman opencv doctest python python-virtualenv
      ;;
    apk)
      apk add --no-cache \
        git curl build-base musl-dev meson ninja gcc g++ pkgconf glib-dev gusb-dev \
        nss-dev openssl-dev cairo-dev gudev-dev pixman-dev opencv-dev python3 py3-pip
      ;;
  esac
}

# ----------------------------------------------------------- the build ----
build_driver() {
  rm -rf "$BUILD"; mkdir -p "$BUILD"

  step "clone libfprint (55b4-experimental)" \
    git clone -q --branch 55b4-experimental "$FORK_URL" "$FORK"
  step "checkout pinned commit" \
    git -C "$FORK" checkout -q "$FORK_REV"
  step "clone patched driver" \
    git clone -q "$REPO_URL" "$SRC"
  step "apply 55a4 driver patch" \
    git -C "$FORK" apply "$SRC/patches/55a4-driver.patch"

  # Some distros ship udev/doctest headers without a .pc meson can find.
  PC="$WORKDIR/pc"; mkdir -p "$PC"
  export PKG_CONFIG_PATH="$PC${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  if ! pkg-config --exists udev 2>/dev/null; then
    libdir=/usr/lib/$(gcc -print-multiarch 2>/dev/null); libdir=${libdir:-/usr/lib}
    printf 'prefix=/usr\nlibdir=%s\nincludedir=/usr/include\nName: udev\nDescription: Linux device management library\nCflags: -I/usr/include\nLibs: -L%s -ludev\n' "$libdir" "$libdir" \
      > "$PC/udev.pc"
    warn "wrote a minimal udev.pc (distro ships none)"
  fi

  echo "== meson configure =="
  ( cd "$FORK" && meson setup _build -Ddrivers=goodixtls55x4 -Dintrospection=false -Ddoc=false ) \
    || die "meson setup failed"
  echo "== compile =="
  ( cd "$FORK" && ninja -C _build ) || die "ninja build failed"
  [ -f "$LIBRARY" ] || die "build did not produce libfprint-2.so.2.0.0"
}

# --------------------------------------------------------- provisioning ---
provision() {
  step "clone goodix-fp-dump"        git clone "$DUMP_URL" "$DUMP"
  step "checkout dump pin"           git -C "$DUMP" checkout -q "$DUMP_REV"
  step "create virtualenv"           python3 -m venv "$DUMP/.venv"
  step_nf "install python deps"       "$DUMP/.venv/bin/pip" install -q pyusb crcmod python-periphery
  printf 'class SpiDev:\n    pass\n' > "$DUMP/spidev.py"
  install -m0644 "$SRC/scripts/provision_psk.py" "$DUMP/"
  # The one-time key write needs fprintd stopped.
  systemctl stop fprintd.service 2>/dev/null || true
  pkill -TERM -x fprintd 2>/dev/null || true; sleep 2
  ( cd "$DUMP" && PYTHONDONTWRITEBYTECODE=1 .venv/bin/python provision_psk.py ) \
    || warn "key provisioning failed; retry: cd $DUMP && .venv/bin/python provision_psk.py"
}

# ----------------------------------------------------------- install ------
install_lib() {
  install -d "$DEST"
  install -m755 "$LIBRARY" "$DEST/libfprint-2.so.2.0.0"
  ln -sf libfprint-2.so.2.0.0 "$DEST/libfprint-2.so.2"
  ln -sf libfprint-2.so.2     "$DEST/libfprint-2.so"
  install -d "$DROPIN"
  cat > "$DROPIN/10-goodix55a4.conf" <<EOF
[Service]
Environment=LD_LIBRARY_PATH=$DEST
EOF
  systemctl daemon-reload
}

restart_fprintd() {
  systemctl stop fprintd.service 2>/dev/null || true
  pkill -TERM -x fprintd 2>/dev/null || true; sleep 2
  systemctl restart fprintd.service 2>/dev/null || true
}

# ---------------------------------------------------------------- PAM ------
configure_pam() {
  [ "$AUTO_PAM" -eq 1 ] || { echo "   (skipping PAM: --no-pam)"; return; }
  case "$PM" in
    apt)
      pam-auth-update --enable fprintd 2>/dev/null \
        || warn "pam-auth-update failed; enable fprintd in /etc/pam.d/common-auth manually"
      ;;
    dnf|yum)
      if have authconfig; then
        authconfig --enablefingerprint --update 2>/dev/null \
          || warn "PAM not configured; run: sudo authconfig --enablefingerprint --update"
      else
        warn "no authconfig; configure PAM manually (see README, Fedora section)"
      fi
      ;;
    *)
      warn "no automatic PAM support for '$PM'; configure manually (see README)" ;;
  esac
}

# ------------------------------------------------------------- verify -----
verify() {
  if fprintd-list 2>/dev/null | grep -qi "55x4\|goodix"; then
    echo "  PASS: Goodix 55A4 detected."
    echo "  Enroll:   sudo fprintd-enroll   (16 touches, vary finger position)"
    echo "  Test:     sudo fprintd-verify"
  else
    warn "device not shown; diagnose: journalctl -u fprintd.service -b"
  fi
}

# -------------------------------------------------------------- main ------
main() {
  [ "$(id -u)" -eq 0 ] || die "re-run with sudo:  sudo bash $0 $*"
  detect_pm
  echo "system: $( . /etc/os-release 2>/dev/null; echo "$PRETTY_NAME" )"
  echo "package manager: $PM"

  echo "== 1/7 install build dependencies =="
  step "install deps" install_deps

  echo "== 2/7 build patched libfprint =="
  step "build driver" build_driver

  echo "== 3/7 install for fprintd only =="
  step "install /opt" install_lib

  echo "== 4/7 provision one-time sensor key =="
  step_nf "provision" provision

  echo "== 5/7 restart fprintd =="
  step_nf "restart"    restart_fprintd

  echo "== 6/7 configure PAM =="
  configure_pam

  echo "== 7/7 verify =="
  verify

  echo
  echo "DONE. Undo anytime:"
  echo "  sudo rm -rf $DEST $DROPIN/10-goodix55a4.conf && sudo systemctl daemon-reload"
}
main "$@"