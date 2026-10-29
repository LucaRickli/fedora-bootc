#!/usr/bin/env bash
#
# The Secure Boot enrollment sets: PK.auth, KEK.auth and db.auth, the signed
# EFI variables systemd-boot writes into the firmware when its menu entry
# "Enroll Secure Boot keys: <set>" is picked while the firmware is in Setup
# Mode (loader.conf(5), secure-boot-enroll). Runs in the `enroll` stage of
# image/base.Containerfile, the one step with the PK and KEK private keys
# (podman secrets, at /run/secrets/), with no network. The OS image carries
# the result in /usr/lib/bootc/install/secureboot-keys/<set>/, which `bootc
# install` copies to the ESP's loader/keys/<set>/ (and
# secureboot-keys.service on every boot after, features/boot/).
#
#   fedora-bootc-and-microsoft  PK, KEK and db, plus Microsoft's KEK and db
#                               certificates (keys/microsoft/): Windows,
#                               shim, and the firmware of graphics, network
#                               and storage cards (option ROMs) still boot
#   fedora-bootc-only           PK, KEK and db alone: nothing else boots
#
# efitools: cert-to-efi-sig-list makes a signature list per certificate (the
# owner GUID of keys/GUID, SB_GUID, for the three; Microsoft's for theirs),
# sign-efi-sig-list signs PK.auth and KEK.auth with PK and db.auth with KEK,
# over the attributes systemd-boot writes them with (its default,
# NV|BS|RT|TIME_BASED_AUTHENTICATED_WRITE). The timestamp is the PK
# certificate's notBefore: the same keys give the same files byte for byte,
# and every file signed under one PK has the same time, so outside Setup Mode,
# where firmware takes a replacement only with a later time, none can be
# written over another (no switching a machine from one set to the other).
# image/sbauth.py, separate code, then reads every file the way the firmware
# will.
#
set -euo pipefail
shopt -s nullglob inherit_errexit
# Microsoft's certificates in byte order of their names, wherever this runs.
export LC_ALL=C

CTX=${CTX:-/ctx}
SECRETS=${SECRETS:-/run/secrets}
OUT=${OUT:-/out}
MS_OWNER=77fa9abd-0359-4d32-bd60-28f4e78f784b

guid=${SB_GUID:-}
[[ $guid =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] ||
    { echo "SB_GUID (keys/GUID) is not a lower-case GUID: '$guid'" >&2; exit 1; }

pk_key=$SECRETS/secureboot_pk_key
pk_cert=$SECRETS/secureboot_pk_cert
kek_key=$SECRETS/secureboot_kek_key
kek_cert=$SECRETS/secureboot_kek_cert
db_cert=$SECRETS/secureboot_cert
for f in "$pk_key" "$pk_cert" "$kek_key" "$kek_cert" "$db_cert"; do
    test -s "$f" || { echo "no secret ${f##*/} (the Justfile's build-base passes it)" >&2; exit 1; }
done
for f in "$pk_cert" "$kek_cert" "$db_cert"; do
    openssl x509 -in "$f" -noout || { echo "${f##*/} is not a PEM certificate" >&2; exit 1; }
done

# Each key with its own certificate, so that a secret in the wrong place fails
# the build instead of an enrollment.
same_key() {
    local key cert
    key=$(openssl pkey -in "$1" -pubout)
    cert=$(openssl x509 -in "$2" -noout -pubkey)
    test -n "$key" && test "$key" = "$cert" || { echo "${1##*/} is not the key of ${2##*/}" >&2; exit 1; }
}
same_key "$pk_key" "$pk_cert"
same_key "$kek_key" "$kek_cert"

# The PK certificate's notBefore, as sign-efi-sig-list -t takes a time (UTC).
start=$(openssl x509 -in "$pk_cert" -noout -startdate)
time=$(date -u -d "${start#notBefore=}" '+%Y-%m-%d %H:%M:%S')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Microsoft's certificates: the committed DER files, which sbauth.py checks
# the signed lists against, and the PEM that cert-to-efi-sig-list reads.
ms_kek=() ms_db=()
for f in "$CTX"/microsoft/KEK/*.der; do ms_kek+=("$f"); done
for f in "$CTX"/microsoft/db/*.der; do ms_db+=("$f"); done
test "${#ms_kek[@]}" -gt 0 && test "${#ms_db[@]}" -gt 0 ||
    { echo "no Microsoft certificates in $CTX/microsoft/KEK/ and db/" >&2; exit 1; }

# esl OWNER CERT OUT: CERT's signature list (one per certificate), appended to OUT.
esl() {
    openssl x509 -inform "$([ "${2##*.}" = der ] && echo DER || echo PEM)" -in "$2" -out "$work/cert.pem"
    cert-to-efi-sig-list -g "$1" "$work/cert.pem" "$work/one.esl"
    cat "$work/one.esl" >> "$3"
}

# make_set NAME [CERT...] -- [CERT...]: the set NAME, with the certificates
# before -- added to KEK and those after it to db, as Microsoft's.
make_set() {
    local dir=$OUT/$1 w=$work/$1 kek_ms=() db_ms=() c
    shift
    while [ "$1" != -- ]; do kek_ms+=("$1"); shift; done
    shift
    db_ms=("$@")
    mkdir -p "$dir" "$w"

    # The owner's list first.
    esl "$guid" "$pk_cert" "$w/PK.esl"
    esl "$guid" "$kek_cert" "$w/KEK.esl"
    esl "$guid" "$db_cert" "$w/db.esl"
    for c in "${kek_ms[@]}"; do esl "$MS_OWNER" "$c" "$w/KEK.esl"; done
    for c in "${db_ms[@]}"; do esl "$MS_OWNER" "$c" "$w/db.esl"; done

    # PK signs PK (Setup Mode takes a self-signed PK) and KEK, KEK signs db.
    sign-efi-sig-list -t "$time" -k "$pk_key" -c "$pk_cert" PK "$w/PK.esl" "$dir/PK.auth" > /dev/null
    sign-efi-sig-list -t "$time" -k "$pk_key" -c "$pk_cert" KEK "$w/KEK.esl" "$dir/KEK.auth" > /dev/null
    sign-efi-sig-list -t "$time" -k "$kek_key" -c "$kek_cert" db "$w/db.esl" "$dir/db.auth" > /dev/null

    # Read back: the signer, the attributes and vendor GUID it signed over,
    # the timestamp, and exactly these certificates (Microsoft's as
    # committed) with their owners.
    python3 "$CTX/image/sbauth.py" verify "$dir/PK.auth" --var PK --signer "$pk_cert" --time "$time" \
        "$guid:$pk_cert"
    python3 "$CTX/image/sbauth.py" verify "$dir/KEK.auth" --var KEK --signer "$pk_cert" --time "$time" \
        "$guid:$kek_cert" "${kek_ms[@]/#/$MS_OWNER:}"
    python3 "$CTX/image/sbauth.py" verify "$dir/db.auth" --var db --signer "$kek_cert" --time "$time" \
        "$guid:$db_cert" "${db_ms[@]/#/$MS_OWNER:}"
}

make_set fedora-bootc-and-microsoft "${ms_kek[@]}" -- "${ms_db[@]}"
make_set fedora-bootc-only --

chmod -R u=rwX,go=rX "$OUT"
ls -lR "$OUT"
