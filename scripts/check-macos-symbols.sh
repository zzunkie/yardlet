#!/bin/zsh
# Checks that macOS's own libraries in an older SDK export every symbol a bundle's executables take
# from them, for each architecture of each executable. A symbol an SDK adds without marking it newer
# than the deployment target is linked strongly, and dyld stops the app before `main` on a macOS that
# lacks it; a Mac or CI image on the newest point release of that macOS may already have it. Here
# the linker resolves the symbols against the SDK's text-based stubs, re-exports included, so the
# macOS itself is not needed: give the SDK of the oldest macOS the bundle supports
# (LSMinimumSystemVersion), such as MacOSX15.0.sdk from Xcode 16.0.
#
#   ./scripts/check-macos-symbols.sh <Yardlet.app> <MacOSX15.0.sdk>
set -euo pipefail
app=${${1:?usage: check-macos-symbols.sh <app bundle> <SDK>}:A}
sdk=${${2:?usage: check-macos-symbols.sh <app bundle> <SDK>}:A}
[[ -f "$app/Contents/Info.plist" && -d "$sdk/usr/lib" ]] || { print -u2 "error: give an app bundle and an SDK"; exit 2; }
minimum=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")
sdk_version=$(/usr/bin/plutil -extract Version raw -o - "$sdk/SDKSettings.json")
print "Checking against the macOS $sdk_version SDK; the bundle needs macOS $minimum"

work=$(/usr/bin/mktemp -d "${${TMPDIR:-/tmp}%/}/macos-symbols.XXXXXX")
trap '/bin/rm -rf "$work"' EXIT
print 'int main(void) { return 0; }' > "$work/main.c"
failed=0
checked=0
for file in "$app"/**/*(.); do
    archs=$(/usr/bin/lipo -archs "$file" 2>/dev/null) || continue
    # otool and nm read "name(member)" as an archive member, as in "Yardlet Helper (GPU)".
    /bin/ln -sf "$file" "$work/binary"
    for arch in ${=archs}; do
        # The system libraries it loads, by the short name nm prints after each import.
        typeset -A stubs=()
        missing_libraries=()
        libraries=$(/usr/bin/otool -L -arch "$arch" "$work/binary")
        for line in ${${(f)libraries}[2,-1]}; do
            [[ "$line" =~ '^[[:space:]]*(/(usr/lib|System/Library)/[^ ]+) \((.*)\)$' ]] || continue
            install=$match[1]
            short=${${install:t}%%.*}
            stub="$sdk${install%.dylib}.tbd"
            if [[ -f "$stub" ]]; then
                stubs[$short]=$stub
            elif [[ "$match[3]" != *weak ]]; then
                missing_libraries+=("$install")
            fi
        done
        # Its strong imports from those libraries; weak ones may be missing at run time.
        imports=$(/usr/bin/nm -m -u -arch "$arch" "$work/binary")
        print -n > "$work/symbols"
        for line in ${(f)imports}; do
            [[ "$line" =~ '^[[:space:]]*\(undefined\) external ([^ ]+) \(from ([^)]+)\)$' ]] || continue
            [[ -n "${stubs[$match[2]]:-}" ]] || continue
            print -- "-Xlinker -u -Xlinker $match[1]" >> "$work/symbols"
            (( ++checked ))
        done
        (( ${#stubs} )) || { print -u2 "error: ${file#$app/} ($arch) loads no system library"; exit 1; }
        if ! /usr/bin/xcrun clang -arch "$arch" -mmacosx-version-min="$minimum" -isysroot "$sdk" \
                "$work/main.c" -o "$work/a.out" "${(@v)stubs}" @"$work/symbols" 2> "$work/link.log" \
                || (( ${#missing_libraries} )); then
            failed=1
            print -u2 "error: ${file#$app/} ($arch) needs what macOS $sdk_version does not have:"
            for library in $missing_libraries; do print -u2 "  library $library"; done
            symbols=$(/usr/bin/sed -nE 's/^ +"(.+)", referenced from:$/\1/p' "$work/link.log")
            if [[ -n "$symbols" ]]; then
                print -- "$symbols" | /usr/bin/xcrun swift-demangle --simplified | /usr/bin/sed 's/^/  /' >&2
            elif [[ -s "$work/link.log" ]]; then
                /usr/bin/sed 's/^/  /' "$work/link.log" >&2
            fi
        fi
    done
done
(( ! failed )) && print "All $checked imports from macOS are in the SDK"
exit $failed
