#!/bin/sh
# Installs the Yardlet host for this account, without root (docs/LINUX_HOST.md, "Installing"): the program in
# ~/.local/lib/yardlet and the command at ~/.local/bin/yardlet. A release carries this script as
# yardlet-host-install.sh beside the packages it installs:
#
#   curl -fsSL https://github.com/zzunkie/yardlet/releases/latest/download/yardlet-host-install.sh | sh
#
# It checks that the computer can run the host (Linux on x86_64 or aarch64, glibc 2.35 or later, libcurl and SQLite),
# downloads yardlet-host-linux-ARCH.tar.gz and its .sha256 from YARDLET_HOST_DOWNLOAD (the latest release by default),
# checks the package against it, and puts the program in place of any installed before it. A package the same as the
# one installed is left as it is. When the host runs as a systemd user service, it is restarted on the new program.
# `yardlet host update` runs this script from the latest release.
set -eu

base=${YARDLET_HOST_DOWNLOAD:-https://github.com/zzunkie/yardlet/releases/latest/download}
lib="$HOME/.local/lib/yardlet"
bin="$HOME/.local/bin"

fail() {
  echo "$*" >&2
  exit 1
}

[ "$(uname -s)" = Linux ] || fail "The Yardlet host runs on Linux."
case $(uname -m) in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) fail "There is no Yardlet host for $(uname -m); it runs on x86_64 and aarch64." ;;
esac

# glibc 2.35 or later: the host is built on Ubuntu 22.04's.
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{ print $2 }') || glibc=
[ -n "$glibc" ] || fail "The Yardlet host needs glibc; this system's C library is another (musl, as on Alpine)."
major=${glibc%%.*}
minor=${glibc#*.}
minor=${minor%%.*}
if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
  fail "The Yardlet host needs glibc 2.35 or later (Ubuntu 22.04, Debian 12, Fedora 36 or later); this system has $glibc."
fi

# The libraries the program links that are not part of glibc.
ldconfig=$(command -v ldconfig || echo /sbin/ldconfig)
missing=
for library in libcurl.so.4 libsqlite3.so.0; do
  "$ldconfig" -p 2>/dev/null | grep -q "$library" || missing="$missing $library"
done
if [ -n "$missing" ]; then
  id=$( (. /etc/os-release 2>/dev/null && echo "$ID $ID_LIKE") || true)
  case " $id " in
    *" debian "* | *" ubuntu "*) hint="sudo apt install curl libsqlite3-0" ;;
    *" fedora "* | *" rhel "*) hint="sudo dnf install libcurl sqlite-libs" ;;
    *" arch "*) hint="sudo pacman -S curl sqlite" ;;
    *" suse "* | *" opensuse "*) hint="sudo zypper install libcurl4 libsqlite3-0" ;;
    *) hint="install libcurl and SQLite with the system's package manager" ;;
  esac
  fail "The Yardlet host needs$missing. To install: $hint"
fi

if command -v curl > /dev/null; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget > /dev/null; then
  fetch() { wget -q "$1" -O "$2"; }
else
  fail "Downloading needs curl or wget."
fi

package="yardlet-host-linux-$arch.tar.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch "$base/$package.sha256" "$work/$package.sha256" || fail "Could not download $base/$package.sha256."
expected=$(awk '{ print $1; exit }' "$work/$package.sha256")
if [ -f "$lib/.package-sha256" ] && [ "$(cat "$lib/.package-sha256")" = "$expected" ]; then
  echo "The Yardlet host $("$lib/yardlet" --version | awk '{ print $2 }') is up to date."
  exit 0
fi
fetch "$base/$package" "$work/$package" || fail "Could not download $base/$package."
actual=$(sha256sum "$work/$package" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "The download does not match its SHA-256 ($actual, not $expected); nothing was installed."

mkdir -p "$work/package"
tar -xzf "$work/$package" -C "$work/package"
new=$("$work/package/yardlet/yardlet" --version) || fail "The downloaded program does not run on this computer."
echo "$expected" > "$work/package/yardlet/.package-sha256"

# The new program goes in beside the old one and takes its place in one rename; a host running keeps its own until it
# restarts.
mkdir -p "$(dirname "$lib")" "$bin"
old=
if [ -d "$lib" ]; then
  old=$( ("$lib/yardlet" --version 2>/dev/null || echo "yardlet ?") | awk '{ print $2 }')
  rm -rf "$lib.previous"
  mv "$lib" "$lib.previous"
fi
mv "$work/package/yardlet" "$lib"
rm -rf "$lib.previous"
ln -sfn "$lib/yardlet" "$bin/yardlet"

version=$(echo "$new" | awk '{ print $2 }')
if [ -n "$old" ]; then
  echo "Updated the Yardlet host from $old to $version."
else
  echo "Installed the Yardlet host $version in $lib."
fi
if command -v systemctl > /dev/null && systemctl --user is-active --quiet yardlet-host.service 2> /dev/null; then
  systemctl --user restart yardlet-host.service
  echo "Restarted the service on it."
elif [ -z "${YARDLET_HOST_UPDATING:-}" ]; then
  echo "Run \`yardlet host service install\` to keep it running, or \`yardlet host start\` to run it here."
fi
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "$bin is not on your PATH; add it, or run $bin/yardlet." ;;
esac
