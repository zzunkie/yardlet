#!/usr/bin/env bash
# Checks the Linux host's direct path end to end on a CI runner, as docs/LINUX_HOST.md, "Direct paths", says it works:
# the host listens on loopback and private addresses alone, a browser's WebSocket handshake is refused, a phone (the
# fixture's, yardlet-remote-fixture --pair) pairs from `yardlet host pair`, starts a chat on a stand-in harness
# (Windows/scripts/fake-harness, which asks to edit a file) through the host, allows the request and gets the answer,
# the pairing's QR code reads back as the link, and stopping the host ends the stand-in and the process it detached.
# Then the host is started again with --every-address, which listens on every address. Needs node, curl and
# zbarimg.
#
#   scripts/linux/check-remote.sh BIN_DIR
set -euo pipefail
bin=${1:?usage: check-remote.sh BIN_DIR}
here=$(cd "$(dirname "$0")" && pwd)
yardlet=$bin/yardlet
home=$(mktemp -d)
export HOME=$home
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_RUNTIME_DIR
logs=$(mktemp -d)

# The stand-in, where a person's own install of Kimi Code would put its command.
mkdir -p "$home/.local/bin" "$home/stand-in"
cp "$here/../../Windows/scripts/fake-harness/cli.js" "$home/stand-in/cli.js"
printf '#!/bin/sh\nexec node "%s/stand-in/cli.js" "$@"\n' "$home" > "$home/.local/bin/kimi"
chmod +x "$home/.local/bin/kimi"
export PATH="$home/.local/bin:$PATH"

start_host() {
  "$yardlet" host start --name 'CI host' "$@" > "$logs/host.log" 2>&1 &
  host=$!
  for _ in $(seq 120); do
    if "$yardlet" host status --json > "$logs/status.json" 2>/dev/null && grep -q '"direct":"ready"' "$logs/status.json"; then
      return 0
    fi
    kill -0 $host || { cat "$logs/host.log"; echo 'The host ended at start'; exit 1; }
    sleep 1
  done
  cat "$logs/host.log"
  echo 'The host did not listen'
  exit 1
}

stop_host() {
  kill -TERM $host
  wait $host || { cat "$logs/host.log"; echo 'The host did not stop cleanly'; exit 1; }
}

# The listening sockets on the port the status names, from /proc: address:port in the kernel's hex, LISTEN is 0A.
listening() {
  local port
  port=$(printf '%04X' "$(sed -E 's/.*"port":([0-9]+).*/\1/' "$logs/status.json")")
  awk -v port=":$port" '$4 == "0A" && substr($2, length($2) - 4) == port { print $2 }' /proc/net/tcp /proc/net/tcp6 | sort
}

# On a failure, what the host, the stand-in and the host's data folder show.
show() {
  kill -KILL ${host:-0} 2>/dev/null || true
  echo '--- host log'; cat "$logs/host.log" 2>/dev/null || true
  echo '--- the stand-in'"'"'s calls'; cat "$home/stand-in/calls.log" 2>/dev/null || echo '(none)'
  echo '--- the data folder'; find "$home/.local/share/yardlet" -type f 2>/dev/null | head -n 60
  for file in $(find "$home/.local/share/yardlet" -type f \( -name '*.log' -o -name '*.jsonl' \) 2>/dev/null | head -n 10); do
    echo "--- $file"; tail -c 3000 "$file"; echo
  done
}
trap show EXIT
start_host
"$yardlet" host status
port=$(sed -E 's/.*"port":([0-9]+).*/\1/' "$logs/status.json")

echo '--- listening sockets (private networks)'
listening | tee "$logs/listening.txt"
if grep -Eq '^(00000000|0{32}):' "$logs/listening.txt"; then echo 'It listens on every address by default'; exit 1; fi
grep -q '^0100007F:' "$logs/listening.txt" || { echo 'It does not listen on loopback'; exit 1; }

echo '--- a browser'
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Origin: https://example.com' \
  "http://127.0.0.1:$port/" || true)
[[ $code == 400 ]] || { echo "A browser's handshake got $code, not 400"; exit 1; }

echo '--- the pairing QR code'
script -qec "$yardlet host pair --no-wait" /dev/null > "$logs/pair-tty.txt"
python3 "$here/qr-text-to-pbm.py" "$logs/pair-tty.txt" "$logs/pair.pbm"
read_back=$(zbarimg --quiet --raw "$logs/pair.pbm")
printed=$(grep -o 'yardlet-remote://[^[:space:]]*' "$logs/pair-tty.txt" | tail -1 | tr -d '\r')
[[ -n $printed && $read_back == "$printed" ]] || { echo "The QR code read back as '$read_back', not '$printed'"; exit 1; }
"$yardlet" host status --json > /dev/null

echo '--- a phone'
link=$("$yardlet" host pair --no-wait --json | sed -E 's/.*"link":"([^"]*)".*/\1/' | sed 's#\\/#/#g')
"$bin/yardlet-remote-fixture" --pair "$link" --new-chat kimi-code --send 'Add the install steps' | tee "$logs/phone.log"
grep -q 'connected through direct' "$logs/phone.log"
"$yardlet" host status
"$yardlet" host status --json | grep -q '"name":"Fixture phone"'

echo '--- stop'
cli=$(cat "$home/stand-in/cli.pid")
grandchild=$(cat "$home/stand-in/grandchild.pid")
kill -0 "$cli" && kill -0 "$grandchild"
stop_host
for pid in "$cli" "$grandchild"; do
  state=$(awk '{ sub(/.*\) /, ""); print $1 }' "/proc/$pid/stat" 2>/dev/null || true)
  [[ -z $state || $state == Z ]] || { echo "Process $pid is still running ($state) after the host stopped"; exit 1; }
done

echo '--- every address'
start_host --every-address
listening | tee "$logs/listening.txt"
grep -Eq '^(00000000|0{32}):' "$logs/listening.txt" || { echo 'It does not listen on every address'; exit 1; }
stop_host
trap - EXIT
echo 'ok'
