#!/bin/sh
# Installs the packed Linux host in a distribution's container and checks it there (docs/LINUX_HOST.md,
# "Distributions"): the installer runs it or refuses it as EXPECT says (`runs`, or `refuses` for a glibc older than
# 2.35), the host starts and answers `status`, and the relay works with this distribution's libcurl. The fixture host
# (yardlet-remote-fixture, built beside the package) opens its room on the local relay, as ws://127.0.0.1:8787 and
# through TLS as wss://127.0.0.1:8443 (scripts/linux/tls-proxy.py, its certificate signed by the test CA in TLS), and
# the fixture's phone pairs through it, starts a chat and gets its answer. Before the system trusts that CA, the wss
# room must not open. It writes one Markdown table row to RESULT.
#
#   check-distribution.sh ARTIFACTS EXPECT RESULT TLS    (as root, in the distribution's container, on the host's network)
set -eu
artifacts=${1:?usage: check-distribution.sh ARTIFACTS EXPECT RESULT}
expect=${2:?}
result=${3:?}
tls=${4:?}
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
    echo "| $name | $glibc | $libcurl | refused: needs glibc 2.35 | - | - |" > "$result"
    exit 0
  fi
  echo "| $name | $glibc | $libcurl | install failed | - | - |" > "$result"
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
[ -n "$up" ] || { cat "$work/host.log"; echo "| $name | $glibc | $libcurl | did not start | - | - |" > "$result"; exit 1; }
"$yardlet" host status
kill -TERM $host
wait $host || { cat "$work/host.log"; echo 'The host did not stop cleanly'; exit 1; }

# The relay with this libcurl: the fixture host's room at RELAY, and a phone through it. Prints yes or no.
relay_chat() {
  "$artifacts/yardlet-remote-fixture" --relay "$1" > "$work/fixture-$2.log" 2>&1 &
  fixture=$!
  link=
  for _ in $(seq 30); do
    link=$(sed -n 's/^Pairing URL[^:]*: //p' "$work/fixture-$2.log" | head -n 1)
    [ -z "$link" ] || break
    sleep 1
  done
  works=no
  if [ -n "$link" ] && timeout 60 "$artifacts/yardlet-remote-fixture" --pair "$link" --new-chat claude-code \
    --send 'Fix the footer' > "$work/phone-$2.log" 2>&1; then
    works=yes
  fi
  kill $fixture 2> /dev/null || true
  wait $fixture 2> /dev/null || true
  { echo "--- fixture host, $1"; head -n 20 "$work/fixture-$2.log"; echo "--- phone, $1"; cat "$work/phone-$2.log"; } >&2
  echo $works
}

plain=$(relay_chat ws://127.0.0.1:8787 plain)

# A certificate the system does not trust keeps the room closed.
"$artifacts/yardlet-remote-fixture" --relay wss://127.0.0.1:8443 > "$work/untrusted.log" 2>&1 &
fixture=$!
for _ in $(seq 20); do grep -q '^Relay: failed' "$work/untrusted.log" && break; sleep 1; done
kill $fixture 2> /dev/null || true
wait $fixture 2> /dev/null || true
echo '--- fixture host, untrusted certificate'
head -n 20 "$work/untrusted.log"
if grep -q '^Relay: connected' "$work/untrusted.log" || ! grep -q '^Relay: failed' "$work/untrusted.log"; then
  echo "| $name | $glibc | $libcurl | runs | $plain | opened with an untrusted certificate |" > "$result"
  cat "$result"
  exit 1
fi

case " $ID ${ID_LIKE:-} " in
  *" debian "* | *" ubuntu "*) cp "$tls/ca.crt" /usr/local/share/ca-certificates/yardlet-test.crt && update-ca-certificates > /dev/null ;;
  *" arch "*) trust anchor --store "$tls/ca.crt" ;;
  *) cp "$tls/ca.crt" /etc/pki/ca-trust/source/anchors/yardlet-test.crt && update-ca-trust ;;
esac
secure=$(relay_chat wss://127.0.0.1:8443 secure)

echo "| $name | $glibc | $libcurl | runs | $plain | $secure |" > "$result"
cat "$result"
[ "$plain" = yes ] && [ "$secure" = yes ] || { echo 'The relay did not work here'; exit 1; }
