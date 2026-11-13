#!/bin/sh
# Installs the packed Linux host in a distribution's container and checks it there (docs/LINUX_HOST.md,
# "Distributions"): the installer runs it or refuses it as EXPECT says (`runs`, or `refuses` for a glibc older than
# 2.35), the host starts and answers `status`, and the relay is tried with this distribution's libcurl. The fixture
# host (yardlet-remote-fixture, built beside the package) opens its room on the local relay at 127.0.0.1:8787 and the
# fixture's phone pairs through it, starts a chat and gets its answer. The check fails when that result and what the
# host says of its libcurl (`relayUnavailable`) disagree, so the host's own reading is what this table shows. It writes
# one Markdown table row to RESULT.
#
#   check-distribution.sh ARTIFACTS EXPECT RESULT    (as root, in the distribution's container, on the host's network)
set -eu
artifacts=${1:?usage: check-distribution.sh ARTIFACTS EXPECT RESULT}
expect=${2:?}
result=${3:?}
. /etc/os-release
name=${PRETTY_NAME:-$ID}

case " $ID ${ID_LIKE:-} " in
  *" debian "* | *" ubuntu "*)
    apt-get update -qq > /dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl ca-certificates libsqlite3-0 > /dev/null
    ;;
  *" fedora "* | *" rhel "* | *" centos "*) dnf install -y -q curl sqlite-libs findutils > /dev/null 2>&1 || true ;;
  *" arch "*) pacman -Sy --noconfirm --needed curl sqlite > /dev/null ;;
esac
glibc=$(getconf GNU_LIBC_VERSION | awk '{ print $2 }')
libcurl=$(curl --version | head -n 1 | sed -E 's/.*libcurl\/([^ ]+).*/\1/')

home=$(mktemp -d)
export HOME="$home"
work=$(mktemp -d)
if ! YARDLET_HOST_DOWNLOAD="file://$artifacts" sh "$artifacts/yardlet-host-install.sh" > "$work/install.log" 2>&1; then
  cat "$work/install.log"
  if [ "$expect" = refuses ] && grep -q 'needs glibc 2.35' "$work/install.log"; then
    echo "| $name | $glibc | $libcurl | refused: needs glibc 2.35 | - |" > "$result"
    exit 0
  fi
  echo "| $name | $glibc | $libcurl | install failed | - |" > "$result"
  exit 1
fi
cat "$work/install.log"
[ "$expect" = runs ] || { echo "The installer did not refuse glibc $glibc"; exit 1; }
yardlet="$home/.local/bin/yardlet"
"$yardlet" --version

"$yardlet" host start > "$work/host.log" 2>&1 &
host=$!
up=
for _ in $(seq 60); do
  if "$yardlet" host status --json > "$work/status.json" 2> /dev/null; then up=yes; break; fi
  sleep 1
done
[ -n "$up" ] || { cat "$work/host.log"; echo "| $name | $glibc | $libcurl | did not start | - |" > "$result"; exit 1; }
"$yardlet" host status
if grep -q '"relayUnavailable"' "$work/status.json"; then says=no; else says=yes; fi
kill -TERM $host
wait $host || { cat "$work/host.log"; echo 'The host did not stop cleanly'; exit 1; }

# The relay with this libcurl: the fixture host's room, and a phone through it.
"$artifacts/yardlet-remote-fixture" --relay ws://127.0.0.1:8787 > "$work/fixture.log" 2>&1 &
fixture=$!
link=
for _ in $(seq 30); do
  link=$(sed -n 's/^Pairing URL[^:]*: //p' "$work/fixture.log" | head -n 1)
  [ -z "$link" ] || break
  sleep 1
done
works=no
if [ -n "$link" ] && timeout 60 "$artifacts/yardlet-remote-fixture" --pair "$link" --new-chat claude-code \
  --send 'Fix the footer' > "$work/phone.log" 2>&1; then
  works=yes
fi
kill $fixture 2> /dev/null || true
echo '--- fixture host'
head -n 20 "$work/fixture.log"
echo '--- phone'
cat "$work/phone.log"

echo "| $name | $glibc | $libcurl | runs; host says relay $([ $says = yes ] && echo usable || echo off) | $works |" > "$result"
cat "$result"
[ "$says" = "$works" ] || { echo "The host says the relay is $says but it $([ $works = yes ] && echo works || echo fails) here"; exit 1; }
