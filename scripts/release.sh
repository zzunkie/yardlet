#!/bin/zsh
# Prepares a release people download and update to (README "Updates"), once for Apple silicon and once
# for Intel Macs: each a Developer ID signed bundle of one architecture with Sparkle's feed for it and
# the public key, the app and its disk image notarized by notarize.sh, and an appcast for the image
# signed with the EdDSA key. It stops there: nothing is pushed, no GitHub release is made and the site
# is not changed; the steps that publish are printed.
#
#   YARDLET_SIGNING_IDENTITY="Developer ID Application: …" ./scripts/release.sh [options]
#
#   --appcast <file>          Apple silicon's appcast published now (the site's appcast.xml), so its
#                             items stay in the new one. Without it the appcast starts with this release.
#   --appcast-x86_64 <file>   The same for Intel Macs (the site's appcast-x86_64.xml).
#   --notes <file>            Release notes (.md or .html) for Sparkle's update window, for both.
#   --ed-key-file <file>      Signs with this private EdDSA key file instead of the key generate_keys
#                             keeps in the login keychain.
#   --skip-notarize           Tries the steps locally: the disk images are not notarized and must not be
#                             published. Any signing identity, ad-hoc included.
#   --output <folder>         Default .build/release-<version>; it must not hold this version's images.
#
#   YARDLET_SPARKLE_FEED_URL    Apple silicon's feed. Default https://yardlet.app/appcast.xml; Intel's is
#                               the same address with -x86_64 before .xml.
#   YARDLET_RELAY_URL           The phone relay built in. Default https://relay.yardlet.app (relay/README.md).
#   YARDLET_SPARKLE_ACCOUNT     The login keychain account that holds the EdDSA key (default yardlet).
#   YARDLET_SPARKLE_PUBLIC_KEY  The public EdDSA key built into the app. Default: generate_keys -p,
#                               which reads it from the login keychain.
#   YARDLET_RELEASE_DOWNLOADS   Where the images are downloaded from, followed by v<version>/.
#                               Default https://github.com/zzunkie/yardlet/releases/download.
#   YARDLET_NOTARY_PROFILE      notarize.sh's keychain profile (default yardlet-notary).
#
# The version is Packaging/Info.plist's: CFBundleShortVersionString names the release and the tag
# v<version>, and Sparkle orders updates by CFBundleVersion, so raise both and commit first.
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
SCRIPTS=${0:A:h}
SPARKLE_BIN="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin"
feed=${YARDLET_SPARKLE_FEED_URL:-https://yardlet.app/appcast.xml}
relay=${YARDLET_RELAY_URL:-https://relay.yardlet.app}
public_key=${YARDLET_SPARKLE_PUBLIC_KEY:-}
account=${YARDLET_SPARKLE_ACCOUNT:-yardlet}
downloads=${YARDLET_RELEASE_DOWNLOADS:-https://github.com/zzunkie/yardlet/releases/download}
downloads=${downloads%/}
website=https://yardlet.app
typeset -A current_appcast=()
notes=""
ed_key_file=""
skip_notarize=0
output=""
while (( $# > 0 )); do
    case $1 in
        --appcast) current_appcast[arm64]=${2:?--appcast needs a file}; shift 2 ;;
        --appcast-x86_64) current_appcast[x86_64]=${2:?--appcast-x86_64 needs a file}; shift 2 ;;
        --notes) notes=${2:?--notes needs a file}; shift 2 ;;
        --ed-key-file) ed_key_file=${2:?--ed-key-file needs a file}; shift 2 ;;
        --skip-notarize) skip_notarize=1; shift ;;
        --output|-o) output=${2:?--output needs a folder}; shift 2 ;;
        -h|--help) /usr/bin/sed -n '2,31p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -u2 "error: unknown argument $1"; exit 2 ;;
    esac
done
for file in ${(v)current_appcast} $notes $ed_key_file; do
    [[ -f "$file" ]] || { print -u2 "error: $file does not exist"; exit 1; }
done
[[ -z "$notes" || "$notes" == *.(md|html) ]] || { print -u2 "error: release notes must be a .md or .html file"; exit 1; }
identity=${YARDLET_SIGNING_IDENTITY:--}
if (( ! skip_notarize )); then
    [[ "$identity" != "-" ]] || {
        print -u2 "error: a release is signed with Developer ID: set YARDLET_SIGNING_IDENTITY (README \"Signing and notarization\")"
        exit 1
    }
    # What is published must be a commit anyone can build again.
    [[ -z "$(/usr/bin/git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]] || {
        print -u2 "error: the checkout has uncommitted changes; commit them first"; exit 1; }
fi

# Sparkle's tools come with the package SwiftPM resolved (Package.resolved pins the version).
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || (cd "$PROJECT_ROOT" && swift package resolve)
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { print -u2 "error: $SPARKLE_BIN/generate_appcast is missing"; exit 1; }
if [[ -z "$public_key" ]]; then
    public_key=$("$SPARKLE_BIN/generate_keys" --account "$account" -p 2>/dev/null) || {
        print -u2 "error: no Sparkle key in the login keychain. Create it once (README \"Updates\"):"
        print -u2 "  $SPARKLE_BIN/generate_keys --account $account"
        exit 1
    }
fi
key_source=(--account "$account")
[[ -n "$ed_key_file" ]] && key_source=(--ed-key-file "$ed_key_file")
app="$PROJECT_ROOT/.build/Yardlet.app"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/Packaging/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PROJECT_ROOT/Packaging/Info.plist")
output=${output:-$PROJECT_ROOT/.build/release-$version}
output=${output:A}
stage=$(/usr/bin/mktemp -d "${${TMPDIR:-/tmp}%/}/yardlet-release.XXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
print "Yardlet $version (build $build) into $output"

typeset -A images=() appcasts=()
for arch in arm64 x86_64; do
    # Apple silicon keeps the names it had before Intel Macs had a build of their own.
    suffix=${${arch:#arm64}:+-$arch}
    arch_feed="${feed%.xml}$suffix.xml"
    folder="$output/$arch"
    dmg="$folder/Yardlet-$version$suffix.dmg"
    [[ ! -e "$dmg" ]] || { print -u2 "error: $dmg already exists; remove it or choose another --output"; exit 1; }
    /bin/mkdir -p "$folder"

    YARDLET_ARCHS=$arch YARDLET_SIGNING_IDENTITY=$identity YARDLET_SPARKLE_FEED_URL=$arch_feed \
        YARDLET_SPARKLE_PUBLIC_KEY=$public_key YARDLET_RELAY_URL=$relay "$SCRIPTS/build-app.sh" release
    [[ "$(plist_value CFBundleShortVersionString) $(plist_value CFBundleVersion)" == "$version $build" ]] || {
        print -u2 "error: $app is not version $version (build $build)"; exit 1; }
    [[ "$(plist_value SUPublicEDKey)" == "$public_key" ]] || { print -u2 "error: $app does not carry the public key"; exit 1; }
    [[ "$(plist_value SUFeedURL)" == "$arch_feed" ]] || { print -u2 "error: $app does not read $arch_feed"; exit 1; }
    # Each image holds one architecture: every executable in the bundle is that architecture alone.
    for file in "$app"/**/*(.); do
        archs=$(/usr/bin/lipo -archs "$file" 2>/dev/null) || continue
        [[ "$archs" == "$arch" || "$file" == "$app/Contents/Frameworks/Sparkle.framework/"* ]] || {
            print -u2 "error: ${file#$app/} is $archs in the $arch image"; exit 1; }
    done

    if (( skip_notarize )); then
        # notarize.sh's image without the notary service: the app beside a link to /Applications.
        /bin/rm -rf "$stage/image"
        /bin/mkdir "$stage/image"
        /usr/bin/ditto "$app" "$stage/image/Yardlet.app"
        /bin/ln -s /Applications "$stage/image/Applications"
        /usr/bin/hdiutil create -volname Yardlet -srcfolder "$stage/image" -format UDZO -ov "$dmg" >/dev/null
        print -u2 "note: --skip-notarize: $dmg is not notarized; do not publish it"
    else
        "$SCRIPTS/notarize.sh" --output "$dmg" "$app"
    fi

    # generate_appcast reads every image in the folder and updates the appcast there, which it names
    # after the app's SUFeedURL; this release's image is the only one, so its item is the only new one
    # and the download prefix applies to it alone.
    appcast="$folder/${arch_feed:t}"
    [[ -n "${current_appcast[$arch]:-}" ]] && /bin/cp "${current_appcast[$arch]}" "$appcast"
    [[ -n "$notes" ]] && /bin/cp "$notes" "$folder/Yardlet-$version$suffix.${notes:e}"
    "$SPARKLE_BIN/generate_appcast" "${key_source[@]}" \
        --download-url-prefix "$downloads/v$version/" \
        --full-release-notes-url "${downloads%/download}" --link "$website" \
        ${notes:+--embed-release-notes} "$folder"
    [[ -f "$appcast" ]] || { print -u2 "error: generate_appcast wrote no ${appcast:t}"; exit 1; }

    # The item as an installed Yardlet will read it: its address, and a signature that the public key
    # built into the app accepts for exactly the image's bytes.
    item="//*[local-name()='item'][*[local-name()='version']='$build']"
    url=$(/usr/bin/xmllint --xpath "string($item/*[local-name()='enclosure']/@url)" "$appcast")
    signature=$(/usr/bin/xmllint --xpath "string($item/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast")
    [[ "$url" == "$downloads/v$version/${dmg:t}" ]] || {
        print -u2 "error: ${appcast:t}'s item for build $build downloads from \"$url\""; exit 1; }
    /usr/bin/xcrun swift - "$public_key" "$signature" "$dmg" <<'SWIFT' || { print -u2 "error: the app's public key does not accept ${appcast:t}'s signature"; exit 1; }
import CryptoKit
import Foundation
let arguments = CommandLine.arguments.suffix(3).map { $0 }
guard let key = Data(base64Encoded: arguments[0]), let signature = Data(base64Encoded: arguments[1]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      let image = FileManager.default.contents(atPath: arguments[2]),
      publicKey.isValidSignature(signature, for: image) else { exit(1) }
SWIFT
    print "  ${appcast:t}: build $build from $url, signature accepted by the app's key"
    images[$arch]=$dmg
    appcasts[$arch]=$appcast
done

repository=${${downloads#https://github.com/}%/releases/download}
cat <<EOF

Ready, not published. To publish $version, in this order (the appcasts point at the release):
  gh release create v$version "${images[arm64]}" "${images[x86_64]}" --repo $repository --title "Yardlet $version"
  cp "${appcasts[arm64]}" "${appcasts[x86_64]}" <yardlet-site checkout>/, then commit and push the site.
  Homebrew cask: version "$version"
    sha256 arm:   "$(/usr/bin/shasum -a 256 "${images[arm64]}" | cut -d' ' -f1)",
           intel: "$(/usr/bin/shasum -a 256 "${images[x86_64]}" | cut -d' ' -f1)"
EOF
