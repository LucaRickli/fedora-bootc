#!/usr/bin/env bash
#
# The enrollment sets the image ships (/usr/lib/bootc/install/secureboot-keys/,
# image/enroll.sh) against what a machine boots once it has enrolled one: the
# db of every set must trust the sealed UKI and systemd-boot, or that machine
# boots nothing with Secure Boot on (systemd-boot enrolls without checking).
# Runs in the `uki` stage of image/seal.Containerfile, after uki.sh, with the
# rechunked rootfs at /target and the UKI in /out, and with no key: a set's
# certificates are public (image/sbauth.sh lists them).
#
set -euo pipefail
shopt -s nullglob

CTX=${CTX:-/ctx}
sets=(/target/usr/lib/bootc/install/secureboot-keys/*/)
test "${#sets[@]}" -gt 0 || { echo "the image ships no enrollment set (image/enroll.sh)" >&2; exit 1; }
ukis=(/out/*.efi)
test "${#ukis[@]}" -eq 1 || { echo "not exactly one UKI in /out: ${ukis[*]}" >&2; exit 1; }
# What bootctl install copies to the ESP: systemd-boot, or its .signed
# variant where one exists.
boots=(/target/usr/lib/systemd/boot/efi/systemd-boot*.efi /target/usr/lib/systemd/boot/efi/systemd-boot*.efi.signed)
test "${#boots[@]}" -gt 0 || { echo "no systemd-boot in /target/usr/lib/systemd/boot/efi" >&2; exit 1; }

certs=$(mktemp -d)
trap 'rm -rf "$certs"' EXIT
for set in "${sets[@]}"; do
    rm -f "$certs"/*
    "$CTX/image/sbauth.sh" certs "$set/db.auth" "$certs"
    for efi in "${ukis[@]}" "${boots[@]}"; do
        trusted='' err=''
        for cert in "$certs"/*.pem; do
            if err=$(sbverify --cert "$cert" "$efi" 2>&1); then trusted=$cert; break; fi
        done
        test -n "$trusted" ||
            { printf '%s: the db of %s does not trust it (sbverify: %s)\n' "$efi" "${set%/}" "$err" >&2; exit 1; }
        echo "$efi: trusted by the db of $(basename "$set")"
    done
done
