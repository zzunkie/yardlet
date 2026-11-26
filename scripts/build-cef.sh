#!/bin/zsh
# Builds the CEF distribution build-app.sh pins: CEF's minimal binary distribution for macOS arm64 at
# the pinned CEF commit, built from source as CEF's automated builders build it (CEF's "Automated
# Build Setup", macOS ARM64: is_official_build=true, PGO profiles, no Chromium history), with the
# proprietary codecs Chromium leaves out unless asked for (proprietary_codecs=true,
# ffmpeg_branding=Chrome: H.264 and AAC through Chromium's FFmpeg). The downloads CEF publishes
# are built without them. symbol_level=1 keeps line tables for crash stacks at a fraction of the
# disk full symbols take, and treat_warnings_as_errors=false keeps a newer macOS SDK's warnings from
# stopping the build; neither changes the code that ships.
#
# It also gives Chromium's keychain groups the team that signs Yardlet's releases, as Chrome's and other
# browsers' builds do with their own BRANDING file: Touch ID passkeys are saved under
# "<team>.com.zzunkie.webauthn" (chrome/browser/webauthn/chrome_web_authentication_delegate.cc builds it
# from MAC_TEAM_ID and MAC_BUNDLE_ID), and only a group with the team's prefix can be granted to the
# browser host by its provisioning profile. The copy of Chromium's BRANDING this build uses
# (the branding_file_path GN arg) changes those two lines and nothing else: the cookie key's keychain
# service, data paths and helper identifiers come from elsewhere. The names are permanent, since the
# passkeys people made live under them (scripts/cef-webauthn-group.sh).
#
#   YARDLET_CEF_TEAM=<team> ./scripts/build-cef.sh <work directory> [parallel compiles]
#
# <team> is the Team ID of the Developer ID certificate that signs releases.
#
# It needs Xcode with its Metal Toolchain (xcodebuild -downloadComponent MetalToolchain; ANGLE
# compiles Metal shaders), git-lfs (some Chromium dependencies are stored with it), about 110 GB free
# and several hours. The work directory must not be in a synced folder and its path must not contain
# spaces. Run again after an interruption, it continues where it stopped. At the end it prints the
# archive and the SHA-256 values build-app.sh pins.
set -euo pipefail
# The Team ID that signs releases (the keychain groups below take it).
team=${YARDLET_CEF_TEAM:-}
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] ||
    { print -u2 "error: set YARDLET_CEF_TEAM to the ten-character Team ID that signs releases"; exit 1; }
work=${1:?usage: build-cef.sh <work directory> [parallel compiles]}
jobs=${2:-$(/usr/sbin/sysctl -n hw.ncpu)}
mkdir -p "$work"
work=${work:A}
[[ "$work" != *" "* ]] || { print -u2 "error: the work directory's path must not contain spaces"; exit 1; }
command -v git-lfs >/dev/null || { print -u2 "error: git-lfs is not on PATH (brew install git-lfs)"; exit 1; }
xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q "Status: installed" ||
    { print -u2 "error: Xcode's Metal Toolchain is missing (xcodebuild -downloadComponent MetalToolchain)"; exit 1; }
# The build takes every core for hours: wait for the heavy-build lock the other builds share
# (scripts/heavy-lock.sh), so they wait for it in turn.
source "${0:A:h}/heavy-lock.sh" && take_heavy_lock "${0:A}" "$@"

cef_branch=8037
cef_commit=564dd6c4aafff558154bd3176eb5d13551db6734
# The keychain group Touch ID passkeys are saved under, after the team: Chromium
# names it MAC_TEAM_ID "." MAC_BUNDLE_ID ".webauthn", so MAC_BUNDLE_ID is the group without ".webauthn".
group=com.zzunkie.webauthn
bundle=${group%.webauthn}
suffix=yardlet

export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=1 treat_warnings_as_errors=false branding_file_path=//chrome/app/theme/yardlet/BRANDING"
export GN_OUT_CONFIGS=Release_GN_arm64
export CEF_ARCHIVE_FORMAT=tar.bz2
export DEPOT_TOOLS_METRICS=0
export PATH="$work/depot_tools:$PATH"

if [[ ! -x "$work/depot_tools/python-bin/python3" ]]; then
    [[ -d "$work/depot_tools" ]] ||
        git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$work/depot_tools"
    (cd "$work/depot_tools" && ./update_depot_tools)
fi
python="$work/depot_tools/python-bin/python3"
src="$work/chromium_git/chromium/src"
out=out/Release_GN_arm64

# CEF's checkout at the pinned commit and Chromium at the version it names, with CEF's patches.
if [[ ! -f "$work/.synced" ]]; then
    # automate-git.py checks Chromium out without history only into a new directory, so a checkout
    # that stopped partway starts again.
    rm -rf "$work/chromium_git/chromium"
    curl -fsSL -o "$work/automate-git.py" \
        "https://raw.githubusercontent.com/chromiumembedded/cef/$cef_commit/tools/automate/automate-git.py"
    "$python" "$work/automate-git.py" --download-dir="$work/chromium_git" --depot-tools-dir="$work/depot_tools" \
        --branch=$cef_branch --checkout=$cef_commit --no-chromium-history --arm64-build --with-pgo-profiles \
        --no-debug-build --no-build --no-distrib
    touch "$work/.synced"
fi
# Chromium's BRANDING with Yardlet's team and the bundle prefix of its keychain groups.
branding="$src/chrome/app/theme/yardlet/BRANDING"
mkdir -p "${branding:h}"
sed -e "s/^MAC_BUNDLE_ID=.*/MAC_BUNDLE_ID=$bundle/" -e "s/^MAC_TEAM_ID=.*/MAC_TEAM_ID=$team/" \
    "$src/chrome/app/theme/chromium/BRANDING" > "$branding"
grep -qx "MAC_TEAM_ID=$team" "$branding" && grep -qx "MAC_BUNDLE_ID=$bundle" "$branding" ||
    { print -u2 "error: $branding does not name the team and $bundle"; exit 1; }
# The rest is what automate-git.py runs next, with the number of parallel compiles given: generate the
# build, build cefclient (the minimal distribution takes the framework from its bundle) and make the
# minimal distribution.
if [[ ! -f "$work/.generated" ]]; then
    (cd "$src/cef" && "$python" tools/gclient_hook.py)
    touch "$work/.generated"
fi
(cd "$src" && autoninja -j "$jobs" -C "$out" cefclient)
distrib="$src/cef/binary_distrib"
(cd "$src/cef/tools" && "$python" make_distrib.py --output-dir="$distrib" --allow-partial --ninja-build \
    --arm64-build --minimal --no-docs --no-symbols --distrib-subdir-suffix=$suffix)

archives=("$distrib"/cef_binary_*_macosarm64_${suffix}_minimal.tar.bz2(om))
archive=$archives[1]
framework="${archive%.tar.bz2}/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
[[ "$("${0:A:h}/cef-webauthn-group.sh" list "$framework")" == "$team.$group"$'\n'"$team.$group-uvk" ]] ||
    { print -u2 "error: the framework's keychain groups are not $team.$group and -uvk"; exit 1; }
print "archive: $archive"
print "CEF_ARCHIVE_SHA256=\"$(/usr/bin/shasum -a 256 "$archive" | cut -d' ' -f1)\""
print "CEF_FRAMEWORK_SHA256=\"$(/usr/bin/shasum -a 256 "$framework" | cut -d' ' -f1)\""
