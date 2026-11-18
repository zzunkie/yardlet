#!/bin/zsh
# Copies a built Yardlet bundle to a QA location under a separate bundle identifier, the nested
# browser host and helper apps included. With YARDLET_PROVISIONING_PROFILE set, only the host keeps
# its original identifier, since the profile grants that App ID. The outer app and helpers still
# use QA identifiers; qa-launch.sh isolates browser storage and uses the mock cookie keychain.
# Passkey QA intentionally uses the profile's real keychain groups. With YARDLET_SIGNING_IDENTITY
# set (not "-") the copy is signed through sign-app.sh; otherwise ad-hoc.
# usage: prepare-qa.sh <source.app> <destination.app> <bundle identifier>
set -euo pipefail
source_app=$1
destination=$2
identifier=$3
signing_identity=${YARDLET_SIGNING_IDENTITY:--}
profile=${YARDLET_PROVISIONING_PROFILE:-}
[[ -z "$profile" || "$signing_identity" != "-" ]] || {
    echo "error: YARDLET_PROVISIONING_PROFILE needs YARDLET_SIGNING_IDENTITY" >&2; exit 1; }
[[ "$destination" == */browser-host-qa/* ]] || { echo "destination must be under a browser-host-qa directory" >&2; exit 2; }
rm -rf "$destination"
mkdir -p "${destination:h}"
/usr/bin/ditto "$source_app" "$destination"

rename_and_sign() {
    local bundle=$1 plist="$1/Contents/Info.plist"
    local current=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
    local renamed=${current/#com.zzunkie.yardlet/$identifier}
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $renamed" "$plist"
    [[ "$signing_identity" == "-" ]] || return 0
    /usr/bin/codesign --force --sign - --requirements "=designated => identifier \"$renamed\"" "$bundle" >/dev/null 2>&1
}

# Innermost first: helpers, then the browser host, then the app.
host="$destination/Contents/Frameworks/Yardlet Browser Host.app"
if [[ -d "$host" ]]; then
    for helper in "$host"/Contents/Frameworks/*.app(N); do rename_and_sign "$helper"; done
    [[ -n "$profile" ]] || rename_and_sign "$host"
fi
for helper in "$destination"/Contents/Helpers/*.app(N); do rename_and_sign "$helper"; done
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${destination:t:r}" "$destination/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${destination:t:r}" "$destination/Contents/Info.plist"
# A QA copy never updates itself: without a feed and key Sparkle stays off (YardletSparkle).
for key in SUFeedURL SUPublicEDKey; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$destination/Contents/Info.plist" 2>/dev/null || true
done
rename_and_sign "$destination"
if [[ "$signing_identity" != "-" ]]; then
    "${0:A:h:h}/sign-app.sh" "$destination"
fi
/usr/bin/codesign --verify --deep --strict "$destination"
echo "$destination"
