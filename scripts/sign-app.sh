#!/bin/zsh
# Signs an assembled Yardlet bundle from the inside out (docs/BROWSER_HOST.md §7): the CEF
# framework's libraries, the framework, the helper apps, the browser host, Sparkle's helpers and
# framework, the MCP server, the lid helper, the simulator host, then the app. Each bundle keeps the
# identifier in its own Info.plist, so a QA copy under another identifier
# (scripts/browser-host-qa/prepare-qa.sh) signs the same way.
#
#   YARDLET_SIGNING_IDENTITY          "-" (default) signs ad-hoc as before. Any other value is a
#                                     codesigning identity (its name, part of it, or its SHA-1):
#                                     hardened runtime and each part's entitlements
#                                     (Packaging/Entitlements).
#   YARDLET_SIGNING_TIMESTAMP         1 asks Apple's timestamp server for a secure timestamp, which
#                                     notarization requires; 0 signs without one. Default: 1 for a
#                                     "Developer ID Application" identity, 0 otherwise.
#   YARDLET_PROVISIONING_PROFILE      A Developer ID provisioning profile for the browser host's App
#                                     ID (<team>.<host identifier>), embedded as the host's
#                                     embedded.provisionprofile with the entitlements it grants.
#   YARDLET_PATCH_CEF_WEBAUTHN_GROUP  1 tries Touch ID passkeys (prototype, off by default; needs
#                                     the profile): see scripts/cef-webauthn-group.sh.
#
# usage: sign-app.sh <Yardlet.app>
set -euo pipefail

SCRIPTS=${0:A:h}
PROJECT_ROOT=${SCRIPTS:h}
ENTITLEMENTS="$PROJECT_ROOT/Packaging/Entitlements"
APP=${1:?usage: sign-app.sh <Yardlet.app>}
APP=${APP:A}
[[ -f "$APP/Contents/Info.plist" ]] || { print -u2 "error: $APP is not an app bundle"; exit 1; }

IDENTITY=${YARDLET_SIGNING_IDENTITY:--}
PROFILE=${YARDLET_PROVISIONING_PROFILE:-}
PATCH_WEBAUTHN_GROUP=${YARDLET_PATCH_CEF_WEBAUTHN_GROUP:-0}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }

APP_IDENTIFIER=$(plist_value CFBundleIdentifier "$APP/Contents/Info.plist")
HOST_APP="$APP/Contents/Frameworks/Yardlet Browser Host.app"
HOST_FRAMEWORKS="$HOST_APP/Contents/Frameworks"
CEF_FRAMEWORK="$HOST_FRAMEWORKS/Chromium Embedded Framework.framework"
CEF_BINARY="$CEF_FRAMEWORK/Versions/A/Chromium Embedded Framework"
MCP="$APP/Contents/Helpers/yardlet-mcp"
LID_HELPER="$APP/Contents/Helpers/yardlet-lid-helper"
SIMULATOR_HOST="$APP/Contents/Helpers/Yardlet Simulator Host.app"
LAUNCH_DAEMONS="$APP/Contents/Library/LaunchDaemons"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

if [[ "$IDENTITY" == "-" ]]; then
    [[ -z "$PROFILE" ]] || { print -u2 "error: YARDLET_PROVISIONING_PROFILE needs YARDLET_SIGNING_IDENTITY"; exit 1; }
    # A plain ad-hoc signature derives its designated requirement from the executable CDHash, so
    # every local rebuild looks like a different app to permission services such as
    # UserNotifications. Each part keeps an identifier-based requirement instead.
    sign() {
        local identifier=$1 target=$2
        shift 2
        /usr/bin/codesign --force --sign - "$@" \
            --requirements "=designated => identifier \"$identifier\"" "$target" >/dev/null
    }
    if [[ -d "$HOST_APP" ]]; then
        for library in "$CEF_FRAMEWORK/Versions/A/Libraries"/*.dylib(N); do
            sign "${library:t:r}" "$library"
        done
        sign "org.cef.framework" "$CEF_FRAMEWORK"
        for helper in "$HOST_FRAMEWORKS"/*.app(N); do
            sign "$(plist_value CFBundleIdentifier "$helper/Contents/Info.plist")" "$helper"
        done
        rm -f "$HOST_APP/Contents/embedded.provisionprofile"
        sign "$(plist_value CFBundleIdentifier "$HOST_APP/Contents/Info.plist")" "$HOST_APP"
    fi
    # Sparkle comes signed ad-hoc by its authors and stays so.
    # A bare executable has no Info.plist to name it, so the identifier is given explicitly.
    [[ -f "$MCP" ]] && sign "$APP_IDENTIFIER.mcp" "$MCP" --identifier "$APP_IDENTIFIER.mcp"
    # The lid helper's identifier is its launchd label, which the app's XPC connection requires.
    [[ -f "$LID_HELPER" ]] && sign "$APP_IDENTIFIER.lid-helper" "$LID_HELPER" --identifier "$APP_IDENTIFIER.lid-helper"
    [[ -d "$SIMULATOR_HOST" ]] && sign "$(plist_value CFBundleIdentifier "$SIMULATOR_HOST/Contents/Info.plist")" "$SIMULATOR_HOST"
    # Its launch constraint names a team, which an ad-hoc signature has none of: without the
    # property list this build offers no helper (LidSleepHelperIdentity.peerRequirement).
    /bin/rm -rf "$LAUNCH_DAEMONS"
    /bin/rmdir "$APP/Contents/Library" 2>/dev/null || true
    sign "$APP_IDENTIFIER" "$APP"
    exit 0
fi

# A named identity: codesign takes the name or its SHA-1; the keychain is only asked for names.
matches=("${(@f)$(/usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/awk -v want="$IDENTITY" -F'"' '/^ *[0-9]+\)/ {
        split($1, field, " "); if (field[2] == want || index($2, want) > 0) print $2 }')}")
matches=(${matches:#})
if (( ${#matches} != 1 )); then
    print -u2 "error: YARDLET_SIGNING_IDENTITY \"$IDENTITY\" matches ${#matches} codesigning identities${matches:+: ${(j:, :)matches}}"
    exit 1
fi
IDENTITY_NAME=${matches[1]}
IS_DEVELOPER_ID=0
[[ "$IDENTITY_NAME" == "Developer ID Application: "* ]] && IS_DEVELOPER_ID=1
TIMESTAMP=${YARDLET_SIGNING_TIMESTAMP:-$IS_DEVELOPER_ID}
timestamp_option=--timestamp=none
[[ "$TIMESTAMP" == 1 ]] && timestamp_option=--timestamp
(( IS_DEVELOPER_ID )) || print -u2 "note: $IDENTITY_NAME is not a Developer ID Application identity; this build cannot be notarized"
[[ "$TIMESTAMP" == 1 ]] || print -u2 "note: signing without a secure timestamp; notarization needs YARDLET_SIGNING_TIMESTAMP=1"

sign() {
    /usr/bin/codesign --force --sign "$IDENTITY_NAME" "$timestamp_option" "$@" >/dev/null
}
# Executables get the hardened runtime; libraries inherit their host process's.
sign_runtime() { sign --options runtime "$@"; }
team_of() { /usr/bin/codesign -dv "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'; }

WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/yardlet-sign.XXXXXX")
trap '/bin/rm -rf "$WORK"' EXIT
# The identity's team, read from a signature it makes, before the profile is matched against it.
/bin/cp /usr/bin/true "$WORK/team-probe"
sign "$WORK/team-probe"
TEAM=$(team_of "$WORK/team-probe")
[[ -n "$TEAM" && "$TEAM" != "not set" ]] || { print -u2 "error: $IDENTITY_NAME signs without a team identifier"; exit 1; }

if [[ -d "$HOST_APP" ]]; then
    HOST_IDENTIFIER=$(plist_value CFBundleIdentifier "$HOST_APP/Contents/Info.plist")
    HOST_ENTITLEMENTS="$WORK/BrowserHost.entitlements"
    /bin/cp "$ENTITLEMENTS/BrowserHost.entitlements" "$HOST_ENTITLEMENTS"
    /bin/rm -f "$HOST_APP/Contents/embedded.provisionprofile"
    [[ "$PATCH_WEBAUTHN_GROUP" != 1 || -n "$PROFILE" ]] || {
        print -u2 "error: YARDLET_PATCH_CEF_WEBAUTHN_GROUP=1 needs YARDLET_PROVISIONING_PROFILE"; exit 1; }

    for library in "$CEF_FRAMEWORK/Versions/A/Libraries"/*.dylib(N); do
        sign --identifier "${library:t:r}" "$library"
    done

    if [[ -n "$PROFILE" ]]; then
        [[ -f "$PROFILE" ]] || { print -u2 "error: $PROFILE does not exist"; exit 1; }
        # The profile is a CMS envelope around a property list; the list is read from its bytes.
        /usr/bin/perl -0777 -ne 'print $1 if /(<\?xml.*?<\/plist>)/s' "$PROFILE" > "$WORK/profile.plist"
        /usr/bin/plutil -lint -s "$WORK/profile.plist" || { print -u2 "error: $PROFILE is not a provisioning profile"; exit 1; }
        profile_team=$(plist_value TeamIdentifier:0 "$WORK/profile.plist")
        profile_app_id=$(plist_value Entitlements:com.apple.application-identifier "$WORK/profile.plist")
        expires=$(/usr/bin/plutil -extract ExpirationDate raw -o - "$WORK/profile.plist")
        [[ "$profile_team" == "$TEAM" ]] || {
            print -u2 "error: the profile is for team $profile_team; $IDENTITY_NAME signs for team $TEAM"; exit 1; }
        [[ "$profile_app_id" == "$TEAM.$HOST_IDENTIFIER" ]] || {
            print -u2 "error: the profile is for App ID $profile_app_id; the browser host needs $TEAM.$HOST_IDENTIFIER"; exit 1; }
        [[ "$expires" > "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || { print -u2 "error: the profile expired on $expires"; exit 1; }
        [[ "$(plist_value ProvisionsAllDevices "$WORK/profile.plist")" == true ]] \
            || print -u2 "note: the profile is not a Developer ID profile; macOS runs this build only on its listed Macs"
        /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $profile_app_id" \
            -c "Add :com.apple.developer.team-identifier string $TEAM" "$HOST_ENTITLEMENTS" >/dev/null

        # Chromium shows Touch ID passkeys only when the browser process holds the keychain group
        # that CEF was built with (crypto::apple::ExecutableHasKeychainAccessGroupEntitlement). A
        # group without this team's prefix can't be granted by the profile, so it stays out:
        # AMFI would refuse to launch the host.
        [[ "$PATCH_WEBAUTHN_GROUP" == 1 ]] && "$SCRIPTS/cef-webauthn-group.sh" patch "$CEF_BINARY" "$TEAM"
        groups=("${(@f)$("$SCRIPTS/cef-webauthn-group.sh" list "$CEF_BINARY")}")
        granted=("${(@f)$(/usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "$WORK/profile.plist" 2>/dev/null \
            | /usr/bin/sed -n 's/^ *\([^ {}][^ ]*\)$/\1/p')}")
        /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" "$HOST_ENTITLEMENTS" >/dev/null
        added=0
        for group in ${groups:#}; do
            if [[ "$group" != "$TEAM."* ]]; then
                print -u2 "note: Touch ID passkeys stay off: CEF expects keychain group \"$group\", which no profile grants (YARDLET_PATCH_CEF_WEBAUTHN_GROUP=1 tries the prototype)"
                continue
            fi
            [[ ${granted[(Ie)$TEAM.*]} -gt 0 || ${granted[(Ie)$group]} -gt 0 ]] || {
                print -u2 "error: the profile does not grant keychain group $group; enable Keychain Sharing on the App ID and download the profile again"; exit 1; }
            /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:$added string $group" "$HOST_ENTITLEMENTS" >/dev/null
            added=$(( added + 1 ))
        done
        (( added )) || /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$HOST_ENTITLEMENTS" >/dev/null
        /bin/cp "$PROFILE" "$HOST_APP/Contents/embedded.provisionprofile"
    fi

    sign "$CEF_FRAMEWORK"
    # Chrome's own signing (chrome/installer/mac/signing/parts.py): the renderer and GPU helpers
    # get allow-jit; the others run under the full hardened runtime.
    for helper in "$HOST_FRAMEWORKS"/*.app(N); do
        case ${helper:t} in
            *"(Renderer).app"|*"(GPU).app") sign_runtime --entitlements "$ENTITLEMENTS/BrowserHelperJIT.entitlements" "$helper" ;;
            *) sign_runtime "$helper" ;;
        esac
    done
    sign_runtime --entitlements "$HOST_ENTITLEMENTS" "$HOST_APP"
fi
if [[ -d "$SPARKLE" ]]; then
    # Sparkle's documented order for signing it with your own identity
    # (sparkle-project.org/documentation/sandboxing/#code-signing): its XPC services, the installer
    # and its progress app, then the framework. Its installer must carry this team's signature for
    # the update to be swapped in atomically. The Downloader service keeps the entitlements Sparkle
    # gave it; the installer's ad-hoc application identifier, which only a provisioning profile
    # could grant under Developer ID, is not kept.
    for service in "$SPARKLE"/Versions/B/XPCServices/*.xpc(N); do
        case ${service:t} in
            Downloader.xpc) sign_runtime --preserve-metadata=entitlements "$service" ;;
            *) sign_runtime "$service" ;;
        esac
    done
    sign_runtime "$SPARKLE/Versions/B/Autoupdate"
    sign_runtime "$SPARKLE/Versions/B/Updater.app"
    sign_runtime "$SPARKLE"
fi
[[ -f "$MCP" ]] && sign_runtime --identifier "$APP_IDENTIFIER.mcp" "$MCP"
[[ -f "$LID_HELPER" ]] && sign_runtime --identifier "$APP_IDENTIFIER.lid-helper" "$LID_HELPER"
# The simulator host needs no entitlement: SimulatorKit and CoreSimulator, which it opens from Xcode at run time, are
# Apple's, so the hardened runtime's library validation takes them.
[[ -d "$SIMULATOR_HOST" ]] && sign_runtime "$SIMULATOR_HOST"
# launchd starts the root lid helper only as signed by this team with its identifier (SpawnConstraint
# in its property list), so a changed executable in the user's bundle does not run as root.
for daemon in "$LAUNCH_DAEMONS"/*.plist(N); do
    /usr/bin/sed -i '' "s|@TEAM_IDENTIFIER@|$TEAM|g" "$daemon"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :SpawnConstraint:team-identifier" "$daemon")" == "$TEAM" ]] \
        || { print -u2 "error: $daemon has no launch constraint for team $TEAM"; exit 1; }
done
sign_runtime --entitlements "$ENTITLEMENTS/Yardlet.entitlements" "$APP"
print -u2 "Signed with $IDENTITY_NAME (team $TEAM), hardened runtime$([[ "$TIMESTAMP" == 1 ]] && print ', secure timestamp')"
