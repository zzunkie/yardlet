#!/usr/bin/env bash
# Builds the Linux host for release and packs it (docs/LINUX_HOST.md, "Installing"): `yardlet` with the Swift runtime
# linked in (--static-swift-stdlib), so it needs only glibc, libcurl and SQLite from the system, and its resources,
# version and built-in relay beside it, as yardlet-host-linux-ARCH.tar.gz with its SHA-256 in OUT_DIR, beside the
# installer as a release carries it (yardlet-host-install.sh). Run it in the image linux-host.yml builds in, whose
# glibc is the oldest the package runs on. The relay is YARDLET_RELAY_URL, else the first line of Packaging/RelayURL
# (out of git), with YARDLET_RELAY_ALTERNATE_URL or Packaging/RelayAlternateURL; a package without one has no relay.
# With --fixture it also builds yardlet-remote-fixture the same way, for the release checks; a release does not
# carry it.
#
#   scripts/linux/package-host.sh OUT_DIR [--fixture]
set -euo pipefail
out=${1:?usage: package-host.sh OUT_DIR [--fixture]}
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$root"
arch=$(uname -m)
version=$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Packaging/Info.plist)
[[ -n $version ]] || { echo 'No version in Packaging/Info.plist'; exit 1; }

products=(--product yardlet)
swift build -c release --static-swift-stdlib --force-resolved-versions "${products[@]}"
bin=$(swift build -c release --static-swift-stdlib --show-bin-path)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/yardlet"
cp "$bin/yardlet" "$stage/yardlet/yardlet"
strip --strip-debug "$stage/yardlet/yardlet"
# The resources the program reads through Bundle.module, which looks for them beside it.
accessor=$(find .build -path '*yardlet*' -name resource_bundle_accessor.swift | head -n 1)
echo "--- $accessor"
cat "$accessor" || true
echo "--- $bin"
ls -la "$bin"
found=
for resources in "$bin"/*.resources "$bin"/*.bundle; do
  [[ -d $resources ]] || continue
  cp -R "$resources" "$stage/yardlet/"
  found=yes
done
[[ -n $found ]] || { echo "No resource bundle beside the program in $bin"; exit 1; }
printf '%s\n' "$version" > "$stage/yardlet/YardletVersion"
first_line() {
  if [[ -n ${1:-} ]]; then printf '%s' "$1"; elif [[ -f $2 ]]; then head -n 1 "$2" | tr -d '[:space:]'; fi
}
relay=$(first_line "${YARDLET_RELAY_URL:-}" Packaging/RelayURL)
if [[ -n $relay ]]; then
  printf '%s' "$relay" > "$stage/yardlet/YardletRelayURL"
  alternate=$(first_line "${YARDLET_RELAY_ALTERNATE_URL:-}" Packaging/RelayAlternateURL)
  [[ -z $alternate ]] || printf '%s' "$alternate" > "$stage/yardlet/YardletRelayAlternateURL"
  echo 'Relay: built in'
else
  echo 'Relay: none built in'
fi
cp LICENSE THIRD_PARTY_NOTICES.md "$stage/yardlet/"

package=yardlet-host-linux-$arch.tar.gz
tar -C "$stage" --owner=0 --group=0 -czf "$out/$package" yardlet
(cd "$out" && sha256sum "$package" > "$package.sha256")
cp scripts/linux/install.sh "$out/yardlet-host-install.sh"
echo "Packed the Yardlet host $version for $arch: $(du -h "$out/$package" | cut -f1), $(du -sh "$stage/yardlet" | cut -f1) unpacked"
echo '--- libraries it needs from the system'
readelf -dW "$stage/yardlet/yardlet" 2>/dev/null | awk '/NEEDED/ { print $NF }' | tr -d '[]'

if [[ ${2:-} == --fixture ]]; then
  swift build -c release --static-swift-stdlib --force-resolved-versions --product yardlet-remote-fixture
  cp "$bin/yardlet-remote-fixture" "$out/yardlet-remote-fixture"
  strip --strip-debug "$out/yardlet-remote-fixture"
fi
