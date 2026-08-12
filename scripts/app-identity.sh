#!/usr/bin/env bash
# Print the code-signing identity of an app bundle (or any binary) — the thing
# TCC actually remembers.
#
#   scripts/app-identity.sh ~/Applications/Papegøye.app
#
# The designated requirement is the interesting line: TCC stores it alongside
# the grant and re-evaluates it against whatever runs from that path. If it is
# byte-identical before and after a rebuild, the grant survives the rebuild. If
# it names a cdhash, the bundle is ad-hoc signed and every rebuild is a new
# program as far as macOS is concerned.

set -euo pipefail

target=${1:-}
if [ -z "$target" ] || [ ! -e "$target" ]; then
    printf "usage: %s <app-or-binary>\n" "$0" >&2
    exit 2
fi

info=$(codesign -dvv "$target" 2>&1 || true)
field() { printf '%s\n' "$info" | sed -n "s/^$1=//p" | head -1; }

printf 'identifier:  %s\n' "$(field Identifier)"
printf 'team:        %s\n' "$(field TeamIdentifier)"
printf 'authority:   %s\n' \
    "$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)"
printf 'requirement: %s\n' \
    "$(codesign -d -r- "$target" 2>/dev/null | sed -n 's/^designated => //p')"

# An Apple Development certificate lasts a year. When it lapses the next build
# signs under a new identity, which costs exactly one re-grant in System
# Settings — worth knowing before it happens rather than after.
certs=$(mktemp -d)
trap 'rm -rf "$certs"' EXIT
if codesign -d --extract-certificates="$certs/cert" "$target" >/dev/null 2>&1 \
    && [ -f "${certs}/cert0" ]; then
    printf 'expires:     %s\n' \
        "$(openssl x509 -inform DER -in "$certs/cert0" -noout -enddate | sed 's/notAfter=//')"
fi
