#!/usr/bin/env bash
# Installs the packed Linux host on a GitHub Actions Ubuntu runner, whose systemd is real, and checks the person's path
# through it (docs/LINUX_HOST.md, "Installing", "Keeping it running", "Updating"): the installer from a served copy of
# the release, `yardlet host service install`, the service finding a harness on the PATH only the login shell's profile
# sets (a systemd service has none of it) and a phone chatting with it, `yardlet host update` to a newer package with
# the service restarted on it, and `yardlet host service uninstall`, which removes the unit, leaves linger as Yardlet
# found it and lists what stays. It uses the runner's own account and home, which the job throws away.
#
#   scripts/linux/check-install.sh ARTIFACTS
set -euo pipefail
artifacts=$(cd "${1:?usage: check-install.sh ARTIFACTS}" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
serve=$(mktemp -d)
logs=$(mktemp -d)
cp "$artifacts"/yardlet-host-* "$serve/"
package=yardlet-host-linux-$(uname -m).tar.gz
# Serves the package again without the relay it carries, which a check must not open rooms on, and with VERSION when
# given, as the next release would serve it.
repack() {
  local work
  work=$(mktemp -d)
  tar -xzf "$serve/$package" -C "$work"
  rm -f "$work/yardlet/YardletRelayURL" "$work/yardlet/YardletRelayAlternateURL"
  [[ -z ${1:-} ]] || printf '%s\n' "$1" > "$work/yardlet/YardletVersion"
  tar -C "$work" -czf "$serve/$package" yardlet
  (cd "$serve" && sha256sum "$package" > "$package.sha256")
}
repack
python3 -m http.server --bind 127.0.0.1 --directory "$serve" 8765 > "$logs/http.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; journalctl --user -u yardlet-host.service --no-pager 2>/dev/null | tail -n 60 || true
  echo "--- the stand-in'"'"'s calls"; cat "$HOME/stand-in/calls.log" 2>/dev/null || echo "(none)"' EXIT
export YARDLET_HOST_DOWNLOAD=http://127.0.0.1:8765

# systemd's user manager for this account, as a login would start it; a runner has no login session of its own.
sudo loginctl enable-linger "$USER"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
for _ in $(seq 30); do [[ -S $XDG_RUNTIME_DIR/bus ]] && break; sleep 1; done
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
systemctl --user show-environment > /dev/null

echo '--- install'
for _ in $(seq 10); do curl -fsS "$YARDLET_HOST_DOWNLOAD/yardlet-host-install.sh" > /dev/null 2>&1 && break; sleep 1; done
curl -fsSL "$YARDLET_HOST_DOWNLOAD/yardlet-host-install.sh" | sh
yardlet=$HOME/.local/bin/yardlet
version=$("$yardlet" --version | awk '{ print $2 }')

# The stand-in harness where only the login shell's profile puts it on the PATH.
mkdir -p "$HOME/stand-in/bin"
cp "$here/../../Windows/scripts/fake-harness/cli.js" "$HOME/stand-in/cli.js"
printf '#!/bin/sh\nexec node "%s/stand-in/cli.js" "$@"\n' "$HOME" > "$HOME/stand-in/bin/kimi"
chmod +x "$HOME/stand-in/bin/kimi"
profile=$HOME/.profile
[[ -f $HOME/.bash_profile ]] && profile=$HOME/.bash_profile
echo "export PATH=\"\$HOME/stand-in/bin:\$PATH\"" >> "$profile"
# ExecStart names node's folder the way a person's PATH would; the runner keeps node outside the default PATH.
echo "export PATH=\"$(dirname "$(command -v node)"):\$PATH\"" >> "$profile"

echo '--- service install'
"$yardlet" host service install --name 'CI service'
cat "$HOME/.config/systemd/user/yardlet-host.service"
wait_for_host() {
  for _ in $(seq 90); do
    if "$yardlet" host status --json > "$logs/status.json" 2> /dev/null && grep -q '"direct":"ready"' "$logs/status.json" \
      && grep -q "\"version\":\"$1\"" "$logs/status.json"; then return 0; fi
    sleep 1
  done
  echo "The service's host $1 did not answer"
  exit 1
}
wait_for_host "$version"
"$yardlet" host status
grep -q '"id":"kimi-code","name":"[^"]*","runtime":"' "$logs/status.json" || {
  echo 'The service did not find the harness on the login shell'"'"'s PATH'; exit 1; }
pid=$(sed -E 's/.*"processID":([0-9]+).*/\1/' "$logs/status.json")

echo '--- a phone through the service'
link=$("$yardlet" host pair --no-wait --json | sed -E 's/.*"link":"([^"]*)".*/\1/' | sed 's#\\/#/#g')
"$artifacts/yardlet-remote-fixture" --pair "$link" --new-chat kimi-code --send 'Add the install steps'

echo '--- update'
next="$version-update-check"
repack "$next"
"$yardlet" host update | tee "$logs/update.txt"
grep -q "Updated the Yardlet host from $version to $next" "$logs/update.txt"
grep -q 'Restarted the service' "$logs/update.txt"
wait_for_host "$next"
[[ $(sed -E 's/.*"processID":([0-9]+).*/\1/' "$logs/status.json") != "$pid" ]] || { echo 'The service did not restart'; exit 1; }
"$yardlet" host update | grep -q 'is up to date'

echo '--- service uninstall'
"$yardlet" host service uninstall | tee "$logs/uninstall.txt"
grep -q 'These stay until you remove them' "$logs/uninstall.txt"
[[ ! -e $HOME/.config/systemd/user/yardlet-host.service ]] || { echo 'The unit is still there'; exit 1; }
if systemctl --user is-active --quiet yardlet-host.service; then echo 'The service still runs'; exit 1; fi
set +e
"$yardlet" host status > /dev/null 2>&1
code=$?
set -e
[[ $code -eq 3 ]] || { echo "status exited $code, not 3, after uninstall"; exit 1; }
# Linger was on before Yardlet looked, so it stays on.
[[ $(loginctl show-user "$USER" --property=Linger --value) == yes ]] || { echo 'Linger went off though Yardlet did not turn it on'; exit 1; }
trap - EXIT
kill $server
echo 'ok'
