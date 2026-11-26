#!/bin/zsh
# The keychain groups Chromium's Touch ID passkeys need, as compiled into a CEF framework binary.
#
# Chromium builds them as MAC_TEAM_IDENTIFIER_STRING "." MAC_BUNDLE_IDENTIFIER_STRING ".webauthn"
# (chrome/browser/webauthn/chrome_web_authentication_delegate.cc) and shows Touch ID only when the
# browser process's keychain-access-groups entitlement contains that exact string
# (crypto/apple/keychain_util.mm). The CEF distribution is built without a team, so its groups are
# ".org.chromium.Chromium.webauthn" and "…-uvk", which no provisioning profile can grant.
#
#   list <binary>          prints the groups the binary expects, one per line
#   patch <binary> <team>  with YARDLET_PATCH_CEF_WEBAUTHN_GROUP=1 in sign-app.sh (release.sh sets it):
#                          rewrites the two constants in place, same length, to
#                          "<team>.com.zzunkie.webauthn" and "<team>.com.zzunkie.webauthn-uvk".
#                          Run on the bundle's copy (the pinned download is never changed) before
#                          the framework is signed. Running it again, or on a CEF built with these
#                          groups already, is a no-op.
#
# These names are permanent: the passkeys people make are keychain items of this group, and Chromium
# looks for none outside it, so a build that names another group loses every passkey made before.
set -euo pipefail
mode=${1:?usage: cef-webauthn-group.sh list <binary> | patch <binary> <team>}
binary=${2:?usage: cef-webauthn-group.sh list <binary> | patch <binary> <team>}
[[ -f "$binary" ]] || { print -u2 "error: $binary does not exist"; exit 1; }

case $mode in
list)
    # A NUL-terminated string that starts the string table entry: [team].<bundle id>.webauthn[-uvk].
    /usr/bin/perl -0777 -ne '
        my %seen;
        while (/(?<![\x20-\x7e])([A-Z0-9]{0,10}\.[A-Za-z0-9.-]{1,80}?\.webauthn(?:-uvk)?)\0/g) { $seen{$1}++ }
        print "$_\n" for sort keys %seen;
    ' "$binary"
    ;;
patch)
    team=${3:?usage: cef-webauthn-group.sh patch <binary> <team>}
    [[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 "error: $team is not a ten-character team identifier"; exit 1; }
    /usr/bin/perl -0777 -i -pe '
        BEGIN { $team = shift @ARGV }
        my %replacement = (
            ".org.chromium.Chromium.webauthn"     => "$team.com.zzunkie.webauthn",
            ".org.chromium.Chromium.webauthn-uvk" => "$team.com.zzunkie.webauthn-uvk",
        );
        for my $from (sort keys %replacement) {
            my $to = $replacement{$from};
            die "length differs: $from -> $to\n" unless length($from) == length($to);
            my $before = () = /(?<![\x20-\x7e])\Q$from\E\0/g;
            my $after = () = /(?<![\x20-\x7e])\Q$to\E\0/g;
            if ($before == 0 && $after == 1) { next }  # already patched for this team
            die "expected one \"$from\", found $before (and $after \"$to\")\n" unless $before == 1 && $after == 0;
            s/(?<![\x20-\x7e])\Q$from\E(?=\0)/$to/;
        }
    ' "$team" "$binary"
    print -u2 "CEF keychain groups now: $(print -l -- "${(@f)$("$0" list "$binary")}" | /usr/bin/paste -sd ' ' -)"
    ;;
*)
    print -u2 "usage: cef-webauthn-group.sh list <binary> | patch <binary> <team>"
    exit 2
    ;;
esac
