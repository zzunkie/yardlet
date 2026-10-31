#!/bin/zsh

set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
CONFIGURATION=${1:-debug}
# Keep the established SwiftPM resource layout when newer toolchains default to Swift Build.
BUILD_SYSTEM=${YARDLET_BUILD_SYSTEM:-native}
APP_DIR="$PROJECT_ROOT/.build/Yardlet.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_WORK_DIR="$PROJECT_ROOT/.build/YardletIconAssets"
ICON_SET_DIR="$ICON_WORK_DIR/AppIcon.iconset"
MACOS_ICON="$ICON_WORK_DIR/AppIcon-1024.png"

FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

# The CPU architectures the bundle's executables are built for: this Mac's by default, or
# YARDLET_ARCHS, such as "x86_64" for Intel Macs or "arm64 x86_64" for a universal bundle, each
# executable joined by lipo. The pinned CEF build is arm64 only, so a bundle for Intel is a debug
# bundle built with YARDLET_WITHOUT_CEF=1.
ARCHS=(${=YARDLET_ARCHS:-})

# Chromium for the in-window browser (docs/BROWSER_HOST.md). Bundles carry this pinned CEF build,
# verified before use: CEF's minimal distribution built from source with Chromium's H.264 and AAC
# decoders, which CEF's own downloads leave out (scripts/build-cef.sh made it). YARDLET_WITHOUT_CEF=1
# builds a debug bundle without it; its browser panel falls back to the WebKit preview, like a plain
# `swift run`.
CEF_VERSION="154.0.28+g564dd6c+chromium-154.0.8037.58"
CEF_NAME="cef_binary_${CEF_VERSION}_macosarm64_codecs_minimal"
CEF_ARCHIVE_URL="https://github.com/zzunkie/yardlet/releases/download/cef-154.0.28-codecs/cef_binary_154.0.28%2Bg564dd6c%2Bchromium-154.0.8037.58_macosarm64_codecs_minimal.tar.bz2"
CEF_ARCHIVE_SHA256="a44771fb3c5fbc3658320c3258f03e0b4d0ee7085d70c36d48c03ef08e44d0ad"
CEF_FRAMEWORK_SHA256="02b51a9be1f8e4a4b97410bd4144a4d8063e8aa6f3fcd0a87f16c9b111a708eb"
CEF_CACHE="$HOME/Library/Caches/Yardlet/CEF"
CEF_DIR=""
if [[ "${YARDLET_WITHOUT_CEF:-}" == 1 ]]; then
    if [[ "$CONFIGURATION" == release ]]; then
        echo "error: release bundles always include CEF; unset YARDLET_WITHOUT_CEF" >&2
        exit 1
    fi
else
    if (( ${ARCHS[(Ie)x86_64]} )); then
        echo "error: the pinned CEF build has no x86_64; build the bundle with YARDLET_WITHOUT_CEF=1" >&2
        exit 1
    fi
    CEF_DIR="$CEF_CACHE/$CEF_NAME"
    CEF_ARCHIVE="$CEF_CACHE/$CEF_NAME.tar.bz2"
    CEF_BINARY="$CEF_DIR/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
    if [[ ! -f "$CEF_BINARY" && -f "$CEF_ARCHIVE" ]]; then
        if [[ "$(/usr/bin/shasum -a 256 "$CEF_ARCHIVE" | cut -d' ' -f1)" != "$CEF_ARCHIVE_SHA256" ]]; then
            echo "error: $CEF_ARCHIVE does not match the pinned SHA-256 $CEF_ARCHIVE_SHA256" >&2
            exit 1
        fi
        /usr/bin/tar -xjf "$CEF_ARCHIVE" -C "$CEF_CACHE"
    fi
    if [[ ! -f "$CEF_BINARY" ]]; then
        cat >&2 <<EOF
error: CEF $CEF_VERSION is not in $CEF_CACHE.
Download and verify the pinned build, then run this script again:
  mkdir -p "$CEF_CACHE" && cd "$CEF_CACHE"
  curl -fL -o "$CEF_NAME.tar.bz2" "$CEF_ARCHIVE_URL"
  echo "$CEF_ARCHIVE_SHA256  $CEF_NAME.tar.bz2" | shasum -a 256 -c -
EOF
        exit 1
    fi
    if [[ "$(/usr/bin/shasum -a 256 "$CEF_BINARY" | cut -d' ' -f1)" != "$CEF_FRAMEWORK_SHA256" ]]; then
        echo "error: $CEF_BINARY does not match the pinned CEF build; remove $CEF_DIR and extract the archive again" >&2
        exit 1
    fi
fi
# Package.swift reads this: an empty value leaves the CEF targets out.
export YARDLET_CEF_DIR="$CEF_DIR"

cd "$PROJECT_ROOT"
# swift build once for this Mac, or once for each of YARDLET_ARCHS.
swift_build() {
    if (( ${#ARCHS} == 0 )); then
        swift build --build-system "$BUILD_SYSTEM" -c "$CONFIGURATION" "$@"
        return
    fi
    local arch
    for arch in $ARCHS; do
        swift build --build-system "$BUILD_SYSTEM" -c "$CONFIGURATION" --arch "$arch" "$@"
    done
}
swift_build --product NativeHarnessClient
# The Yardlet MCP server harnesses start over stdio (docs/AGENT_BROWSER_TOOLS.md).
swift_build --product yardlet-mcp
# The launch daemon behind "Keep tasks working with the lid closed" (docs/REMOTE_V2_DESIGN.md §6.5).
swift_build --product yardlet-lid-helper
if [[ -n "$CEF_DIR" ]]; then
    swift_build --product YardletCEFHelper
    swift_build --product YardletBrowserHost
fi
BIN_DIRS=("${(@f)$(swift_build --show-bin-path)}")
# Resources are the same for every architecture and come from the first.
BIN_DIR=$BIN_DIRS[1]
# Puts a built executable in the bundle: one architecture's as built, several joined by lipo.
install_executable() {
    local name=$1 destination=$2
    if (( ${#BIN_DIRS} > 1 )); then
        /usr/bin/lipo -create -output "$destination" "${^BIN_DIRS[@]}/$name"
    else
        cp "$BIN_DIR/$name" "$destination"
    fi
    chmod 755 "$destination"
}

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"

# Yardlet's own Google OAuth app (a Desktop client), so a person only signs in to connect Gmail,
# Calendar, and Drive (docs/CONNECTORS.md, "Google"). The client stays out of git: the environment's
# YARDLET_GOOGLE_CLIENT_ID and YARDLET_GOOGLE_CLIENT_SECRET, or Packaging/GoogleOAuthClient.json
# (Google's downloaded client file, or {"client_id": …, "client_secret": …}). Without either the
# bundle carries none and Settings asks for an app of the person's own.
GOOGLE_CLIENT_FILE="$PROJECT_ROOT/Packaging/GoogleOAuthClient.json"
GOOGLE_CLIENT_ID=${YARDLET_GOOGLE_CLIENT_ID:-}
GOOGLE_CLIENT_SECRET=${YARDLET_GOOGLE_CLIENT_SECRET:-}
if [[ -z "$GOOGLE_CLIENT_ID" && -f "$GOOGLE_CLIENT_FILE" ]]; then
    google_client_value() {
        /usr/bin/plutil -extract "installed.$1" raw -o - "$GOOGLE_CLIENT_FILE" 2>/dev/null \
            || /usr/bin/plutil -extract "$1" raw -o - "$GOOGLE_CLIENT_FILE" 2>/dev/null \
            || true
    }
    GOOGLE_CLIENT_ID=$(google_client_value client_id)
    GOOGLE_CLIENT_SECRET=$(google_client_value client_secret)
fi
if [[ -n "$GOOGLE_CLIENT_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Add :YardletGoogleOAuthClientID string $GOOGLE_CLIENT_ID" "$CONTENTS_DIR/Info.plist"
    if [[ -n "$GOOGLE_CLIENT_SECRET" ]]; then
        /usr/libexec/PlistBuddy -c "Add :YardletGoogleOAuthClientSecret string $GOOGLE_CLIENT_SECRET" "$CONTENTS_DIR/Info.plist"
        echo "Google OAuth app: built in" >&2
    else
        # Google's token endpoint refuses a Desktop client's code without its secret.
        echo "warning: Google OAuth app built in without its client secret; sign-in will fail" >&2
    fi
else
    echo "Google OAuth app: none built in (Packaging/GoogleOAuthClient.json is absent)" >&2
fi
unset GOOGLE_CLIENT_SECRET

# Yardlet's own Microsoft Entra app (a public client: no secret), so a person only signs in to
# connect Outlook, OneDrive, and Teams (docs/CONNECTORS.md, "Microsoft 365"). The environment's
# YARDLET_MICROSOFT_CLIENT_ID, or Packaging/MicrosoftOAuthClient.json ({"client_id": …}), which
# stays out of git so that others build with their own. Without either the bundle carries no app,
# and each person registers one.
MICROSOFT_CLIENT_FILE="$PROJECT_ROOT/Packaging/MicrosoftOAuthClient.json"
MICROSOFT_CLIENT_ID=${YARDLET_MICROSOFT_CLIENT_ID:-}
if [[ -z "$MICROSOFT_CLIENT_ID" && -f "$MICROSOFT_CLIENT_FILE" ]]; then
    MICROSOFT_CLIENT_ID=$(/usr/bin/plutil -extract client_id raw -o - "$MICROSOFT_CLIENT_FILE" 2>/dev/null || true)
fi
if [[ -n "$MICROSOFT_CLIENT_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Add :YardletMicrosoftOAuthClientID string $MICROSOFT_CLIENT_ID" "$CONTENTS_DIR/Info.plist"
    echo "Microsoft app: built in" >&2
else
    echo "Microsoft app: none built in (Packaging/MicrosoftOAuthClient.json is absent)" >&2
fi

# Sparkle updates (README "Updates") only in a bundle built with both the appcast's address and the
# public EdDSA key, as scripts/release.sh builds it. Without them the bundle carries Sparkle's
# framework unused: no Sparkle item, no update request, and Install Update… as before.
SPARKLE_FEED_URL=${YARDLET_SPARKLE_FEED_URL:-}
SPARKLE_PUBLIC_KEY=${YARDLET_SPARKLE_PUBLIC_KEY:-}
if [[ -n "$SPARKLE_FEED_URL" || -n "$SPARKLE_PUBLIC_KEY" ]]; then
    [[ -n "$SPARKLE_FEED_URL" && -n "$SPARKLE_PUBLIC_KEY" ]] || {
        echo "error: Sparkle needs both YARDLET_SPARKLE_FEED_URL and YARDLET_SPARKLE_PUBLIC_KEY" >&2; exit 1; }
    # Checking and downloading in the background are on by default, as in the Codex and Claude apps;
    # Settings › General turns checking off.
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" \
        -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" \
        -c "Add :SUEnableAutomaticChecks bool true" \
        -c "Add :SUAutomaticallyUpdate bool true" "$CONTENTS_DIR/Info.plist"
    echo "Sparkle updates: $SPARKLE_FEED_URL" >&2
else
    echo "Sparkle updates: off (no YARDLET_SPARKLE_FEED_URL and YARDLET_SPARKLE_PUBLIC_KEY)" >&2
fi
# The Yardlet relay for phones away from this network (relay/, docs/REMOTE_V2_DESIGN.md §12):
# YARDLET_RELAY_URL, which scripts/release.sh sets to https://relay.yardlet.app, or the first line of
# Packaging/RelayURL (out of git, for other builds). Without either the bundle carries none and phones
# reach the Mac directly.
RELAY_URL=${YARDLET_RELAY_URL:-}
if [[ -z "$RELAY_URL" && -f "$PROJECT_ROOT/Packaging/RelayURL" ]]; then
    RELAY_URL=$(head -n 1 "$PROJECT_ROOT/Packaging/RelayURL" | tr -d '[:space:]')
fi
if [[ -n "$RELAY_URL" ]]; then
    /usr/libexec/PlistBuddy -c "Add :YardletRelayURL string $RELAY_URL" "$CONTENTS_DIR/Info.plist"
    echo "Relay: built in" >&2
else
    echo "Relay: none built in (Packaging/RelayURL is absent)" >&2
fi
install_executable NativeHarnessClient "$MACOS_DIR/Yardlet"

[[ "$ICON_WORK_DIR" == "$PROJECT_ROOT/.build/YardletIconAssets" ]]
if [[ -e "$ICON_WORK_DIR" ]]; then
    [[ ! -L "$ICON_WORK_DIR" ]]
    rm -rf "$ICON_WORK_DIR"
fi
mkdir -p "$ICON_SET_DIR"
cp "$PROJECT_ROOT/Packaging/AppIcon-1024.png" "$MACOS_ICON"
sips -z 16 16 "$MACOS_ICON" --out "$ICON_SET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$MACOS_ICON" --out "$ICON_SET_DIR/icon_16x16@2x.png" >/dev/null
cp "$ICON_SET_DIR/icon_16x16@2x.png" "$ICON_SET_DIR/icon_32x32.png"
sips -z 64 64 "$MACOS_ICON" --out "$ICON_SET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$MACOS_ICON" --out "$ICON_SET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$MACOS_ICON" --out "$ICON_SET_DIR/icon_128x128@2x.png" >/dev/null
cp "$ICON_SET_DIR/icon_128x128@2x.png" "$ICON_SET_DIR/icon_256x256.png"
sips -z 512 512 "$MACOS_ICON" --out "$ICON_SET_DIR/icon_256x256@2x.png" >/dev/null
cp "$ICON_SET_DIR/icon_256x256@2x.png" "$ICON_SET_DIR/icon_512x512.png"
cp "$MACOS_ICON" "$ICON_SET_DIR/icon_512x512@2x.png"
rm -f "$RESOURCES_DIR/AppIcon.icns" "$RESOURCES_DIR/Assets.car"
iconutil -c icns "$ICON_SET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

RESOURCE_BUNDLE="$BIN_DIR/NativeHarnessClient_NativeHarnessClient.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    rm -rf "$RESOURCES_DIR/NativeHarnessClient_NativeHarnessClient.bundle"
    for localization in "$RESOURCE_BUNDLE"/*.lproj; do
        [[ -d "$localization" ]] || continue
        /usr/bin/ditto "$localization" "$RESOURCES_DIR/${localization:t}"
    done
    # Enumerate current sources so removed harness marks cannot survive in an
    # incremental SwiftPM resource bundle or the previous application bundle.
    # The vault for agents reads which hosts are public suffixes from here (VaultSite.swift).
    /usr/bin/ditto "$RESOURCE_BUNDLE/public_suffix_list.dat" "$RESOURCES_DIR/public_suffix_list.dat"
    rm -rf "$RESOURCES_DIR/HarnessLogos"
    logo_assets=("$PROJECT_ROOT/Sources/NativeHarnessClient/Resources/HarnessLogos"/*.png(N))
    if (( ${#logo_assets} > 0 )); then
        mkdir -p "$RESOURCES_DIR/HarnessLogos"
        for logo in "${logo_assets[@]}"; do
            /usr/bin/ditto "$RESOURCE_BUNDLE/${logo:t}" "$RESOURCES_DIR/HarnessLogos/${logo:t}"
        done
    fi
fi

SWIFTTERM_BUNDLE="$BIN_DIR/SwiftTerm_SwiftTerm.bundle"
rm -rf "$APP_DIR/SwiftTerm_SwiftTerm.bundle"
if [[ -d "$SWIFTTERM_BUNDLE" ]]; then
    rm -rf "$RESOURCES_DIR/SwiftTerm_SwiftTerm.bundle"
    /usr/bin/ditto "$SWIFTTERM_BUNDLE" "$RESOURCES_DIR/SwiftTerm_SwiftTerm.bundle"
fi

cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
# Chromium's own notices come with Chromium (THIRD_PARTY_NOTICES.md), so not in a bundle built without it.
rm -f "$RESOURCES_DIR/CHROMIUM_CREDITS.html"

HELPERS_DIR="$CONTENTS_DIR/Helpers"
mkdir -p "$HELPERS_DIR"
install_executable yardlet-mcp "$HELPERS_DIR/yardlet-mcp"
# The lid helper and its launchd property list, named from the bundle identifier
# (LidSleepHelperIdentity), which SMAppService.daemon(plistName:) finds in Contents/Library/LaunchDaemons.
install_executable yardlet-lid-helper "$HELPERS_DIR/yardlet-lid-helper"
LAUNCH_DAEMONS_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
rm -rf "$LAUNCH_DAEMONS_DIR"
mkdir -p "$LAUNCH_DAEMONS_DIR"
LID_HELPER_LABEL="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$CONTENTS_DIR/Info.plist").lid-helper"
sed -e "s|@LABEL@|$LID_HELPER_LABEL|g" "$PROJECT_ROOT/Packaging/LidHelper-LaunchDaemon.plist" \
    > "$LAUNCH_DAEMONS_DIR/$LID_HELPER_LABEL.plist"
/usr/bin/plutil -lint -s "$LAUNCH_DAEMONS_DIR/$LID_HELPER_LABEL.plist"

# A previous CEF build must not leave Chromium inside a bundle built without it.
if [[ -e "$FRAMEWORKS_DIR" ]]; then
    [[ ! -L "$FRAMEWORKS_DIR" ]]
    rm -rf "$FRAMEWORKS_DIR"
fi
if [[ -n "$CEF_DIR" ]]; then
    # Chromium runs in its own app bundle inside Yardlet: the browser host, with the CEF framework
    # and helper apps in its Contents/Frameworks as CEF's bundle layout expects. The helpers'
    # sandbox only lets them read inside the host bundle, so nothing CEF needs may sit outside it.
    SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CONTENTS_DIR/Info.plist")
    BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$CONTENTS_DIR/Info.plist")
    BASE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$CONTENTS_DIR/Info.plist")
    HOST_APP="$FRAMEWORKS_DIR/Yardlet Browser Host.app"
    HOST_IDENTIFIER="$BASE_IDENTIFIER.browser-host"
    HOST_FRAMEWORKS="$HOST_APP/Contents/Frameworks"
    mkdir -p "$HOST_APP/Contents/MacOS" "$HOST_FRAMEWORKS"

    CEF_FRAMEWORK_SOURCE="$CEF_DIR/Release/Chromium Embedded Framework.framework"
    [[ -d "$CEF_FRAMEWORK_SOURCE" ]]
    cp "$CEF_DIR/CREDITS.html" "$RESOURCES_DIR/CHROMIUM_CREDITS.html"
    CEF_FRAMEWORK="$HOST_FRAMEWORKS/Chromium Embedded Framework.framework"
    # Current Xcode requires a versioned framework layout; the distribution ships it flat.
    mkdir -p "$CEF_FRAMEWORK/Versions"
    /usr/bin/ditto "$CEF_FRAMEWORK_SOURCE" "$CEF_FRAMEWORK/Versions/A"
    # Chromium's UI strings only for Yardlet's own languages (about 49 MB less).
    for localization in "$CEF_FRAMEWORK/Versions/A/Resources"/*.lproj(N); do
        case ${localization:t} in
            en.lproj|ko.lproj) ;;
            *) rm -rf "$localization" ;;
        esac
    done
    ln -s A "$CEF_FRAMEWORK/Versions/Current"
    for entry in "Chromium Embedded Framework" Libraries Resources; do
        ln -s "Versions/Current/$entry" "$CEF_FRAMEWORK/$entry"
    done

    # CEF derives each process type's helper from the base helper path by these suffixes.
    for suffix in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
        helper_name="Yardlet Helper$suffix"
        helper_app="$HOST_FRAMEWORKS/$helper_name.app"
        identifier_suffix=${${suffix//[() ]/}:l}
        helper_identifier="$BASE_IDENTIFIER.helper${identifier_suffix:+.$identifier_suffix}"
        mkdir -p "$helper_app/Contents/MacOS"
        install_executable YardletCEFHelper "$helper_app/Contents/MacOS/$helper_name"
        sed -e "s|@EXECUTABLE_NAME@|$helper_name|g" \
            -e "s|@BUNDLE_IDENTIFIER@|$helper_identifier|g" \
            -e "s|@SHORT_VERSION@|$SHORT_VERSION|g" \
            -e "s|@BUNDLE_VERSION@|$BUNDLE_VERSION|g" \
            "$PROJECT_ROOT/Packaging/CEF/Helper-Info.plist" > "$helper_app/Contents/Info.plist"
    done

    install_executable YardletBrowserHost "$HOST_APP/Contents/MacOS/Yardlet Browser Host"
    sed -e "s|@BUNDLE_IDENTIFIER@|$HOST_IDENTIFIER|g" \
        -e "s|@SHORT_VERSION@|$SHORT_VERSION|g" \
        -e "s|@BUNDLE_VERSION@|$BUNDLE_VERSION|g" \
        "$PROJECT_ROOT/Packaging/CEF/BrowserHost-Info.plist" > "$HOST_APP/Contents/Info.plist"
fi
mkdir -p "$FRAMEWORKS_DIR"
/usr/bin/ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORKS_DIR/Sparkle.framework"

# Inside out, ad-hoc unless YARDLET_SIGNING_IDENTITY names an identity (hardened runtime,
# entitlements, and the browser host's provisioning profile; see the script).
"$PROJECT_ROOT/scripts/sign-app.sh" "$APP_DIR"
echo "$APP_DIR"
