#!/usr/bin/env bash
# Build Papegøye.app around the release binary and sign it (gh#37).
#
#   scripts/build-app.sh [stage-dir]        # default: build/
#
# Why the bundle exists at all: TCC keys a permission grant to the code
# signature, and an *unsigned* binary's signature is its own contents. Every
# rebuild is therefore a different program to macOS — the Accessibility grant
# is dropped and a fresh, indistinguishable row appears in the list. Signing
# with a certificate that outlives the build keeps the identity constant, so
# the grant survives `make install`.
#
# The identity is discovered, never hardcoded: its hash differs per machine and
# the certificate expires. Override with CODESIGN_IDENTITY if the machine has
# more than one and you want a specific one.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

stage_dir=${1:-build}
app="$stage_dir/Papegøye.app"
contents="$app/Contents"

red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }
dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }

# 1. the signing identity, before anything else is built ----------------------
#
# `security find-identity -v -p codesigning` lists only identities that are
# valid *and* usable for signing code, one per line:
#
#   1) DDD5…AB70 "Apple Development: someone@example.com (Z23WY6T2TB)"
#
# Preference order matters on a machine with several: a Developer ID cert is
# the one distribution would use (#36), so if it is there, prefer it.
codesign_identities() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^ *[0-9][0-9]*) [0-9A-Fa-f]\{40\} "\(.*\)"$/\1/p'
}

pick_identity() {
    local identities prefix
    identities=$(codesign_identities)
    for prefix in "Developer ID Application:" "Apple Development:" "Apple Distribution:"; do
        local match
        match=$(printf '%s\n' "$identities" | grep -m1 -F "$prefix" || true)
        if [ -n "$match" ]; then
            printf '%s\n' "$match"
            return 0
        fi
    done
    return 1
}

identity=${CODESIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    if ! identity=$(pick_identity); then
        red "no code-signing identity found."
        red ""
        red "  security find-identity -v -p codesigning   # lists what this Mac has"
        red ""
        red "A free Apple ID in Xcode → Settings → Accounts → Manage Certificates → +"
        red "gives you an \"Apple Development\" certificate, which is all this needs."
        red "Signing ad-hoc instead (CODESIGN_IDENTITY=-) builds a bundle, but its"
        red "identity changes on every rebuild — the very thing gh#37 is about."
        exit 1
    fi
fi

if [ "$identity" = "-" ]; then
    red "warning: signing ad-hoc. The identity changes on every rebuild, so the"
    red "         Accessibility grant will NOT survive — this is for CI, not for"
    red "         the machine you dictate on."
fi

# 2. version, from git --------------------------------------------------------
version=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
[ -n "$version" ] || version="0.0.0"
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)

# 3. compile ------------------------------------------------------------------
dim "→ swift build -c release"
swift build -c release
bin_path=$(swift build -c release --show-bin-path)
binary="$bin_path/parrot"
[ -x "$binary" ] || { red "no executable at $binary"; exit 1; }

# 4. assemble the bundle ------------------------------------------------------
dim "→ assembling $app"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"

cp "$binary" "$contents/MacOS/parrot"

sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$build_number/" \
    packaging/Info.plist > "$contents/Info.plist"
plutil -lint -s "$contents/Info.plist"

# SwiftPM resource bundles for the dependencies. The bare binary has shipped
# without them, but inside a bundle Bundle.module finds them here — so put them
# where they can be found rather than relying on nothing ever asking.
for bundle in "$bin_path"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$contents/Resources/"
done

dim "→ rendering the icon"
iconset="$stage_dir/AppIcon.iconset"
swift packaging/render-icon.swift packaging/AppIcon.svg "$iconset"
iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"
rm -rf "$iconset"

# 5. sign ---------------------------------------------------------------------
dim "→ codesign as: $identity"
codesign --force \
         --sign "$identity" \
         --identifier "no.bredebjorhovd.papegoye" \
         --options runtime \
         --entitlements packaging/parrot.entitlements \
         --timestamp=none \
         "$app"

codesign --verify --strict --deep "$app"

green "✓ $app"
scripts/app-identity.sh "$app" | sed 's/^/  /'
