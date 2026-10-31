#!/usr/bin/env bash
#
# Reads a Secure Boot enrollment file (PK.auth, KEK.auth or db.auth: an
# EFI_VARIABLE_AUTHENTICATION_2 followed by the variable's
# EFI_SIGNATURE_LISTs, UEFI 2.10 sections 8.2.2 and 32.4.1) and checks it the
# way systemd-boot writes it and edk2 accepts it. Bash and coreutils, and the
# openssl command for verify's signature (certs runs where there is no
# openssl). image/enroll.sh checks every file it signs with it;
# image/uki-trust.sh lists a db.auth's certificates with it.
#
#   sbauth.sh verify FILE --var NAME --signer CERT --time 'YYYY-MM-DD HH:MM:SS' OWNER:CERT...
#       FILE is the variable NAME (PK, KEK or db), signed by CERT's key over
#       the attributes systemd-boot writes it with, stamped with that time
#       (UTC), and holds exactly these certificates (PEM or DER), each with
#       its owner GUID, in this order.
#   sbauth.sh certs FILE DIR
#       every X.509 certificate of FILE's signature lists, as DIR/<n>.pem
#
# The checks follow edk2 (SecurityPkg/Library/AuthVariableLib/AuthService.c),
# where a file that fails them is refused by the firmware, except that this is
# stricter where firmware differs: older edk2 (before edk2-stable202302)
# refuses a PKCS#7 wrapped in a ContentInfo, so only the bare SignedData that
# efitools writes passes here.
#
# A bash variable holds no NUL byte, so files are read as hex, two digits a
# byte, and offsets count bytes. Bytes go out through dd, or printf for the
# few built here.
#
set -euo pipefail
shopt -s inherit_errexit
export LC_ALL=C

# The vendor GUID is part of what is signed, and is in no file: systemd-boot
# passes the one of the variable's name to SetVariable().
declare -A VENDOR=(
    [PK]=8be4df61-93ca-11d2-aa0d-00e098032b8c # EFI_GLOBAL_VARIABLE
    [KEK]=8be4df61-93ca-11d2-aa0d-00e098032b8c
    [db]=d719b2cb-3d3a-4596-a3bc-dad00e67656f # EFI_IMAGE_SECURITY_DATABASE_GUID
)
# NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS |
# TIME_BASED_AUTHENTICATED_WRITE_ACCESS (0x27, here its little-endian bytes):
# what systemd-boot writes each variable with (src/boot/secure-boot.c), and so
# what the signature covers.
ATTRS=27000000
CERT_TYPE_PKCS7=4aafd29d68df49ee8aa9347d375665a7 # EFI_CERT_TYPE_PKCS7_GUID
CERT_X509=a5c059a194e44aa787b5ab155c2bf072       # EFI_CERT_X509_GUID
WIN_CERT_TYPE_EFI_GUID=0x0EF1
SHA256_OID=608648016503040201      # 2.16.840.1.101.3.4.2.1
RSA_OID=2a864886f70d010101         # 1.2.840.113549.1.1.1
SIGNED_DATA_OID=2a864886f70d010702 # 1.2.840.113549.1.7.2
BEGIN='-----BEGIN CERTIFICATE-----' END='-----END CERTIFICATE-----'
BEGIN_HEX=2d2d2d2d2d424547494e2043455254494649434154452d2d2d2d2d # $BEGIN

die() { printf '%s: %s\n' "$file" "$1" >&2; exit 1; }

usage() {
    printf '%s\n' "usage: ${0##*/} verify FILE --var NAME --signer CERT --time 'YYYY-MM-DD HH:MM:SS' OWNER:CERT..." \
        "       ${0##*/} certs FILE DIR" >&2
    exit 2
}

# hex FILE: FILE's bytes as hex, into X (od -v: without it, od writes
# repeated lines as "*").
hex() { X=$(od -An -tx1 -v -- "$1" 2> "$tmp/err" | tr -d ' \n') || die "$(< "$tmp/err")"; }

# le HEX: HEX's bytes as a little-endian number, into R.
le() {
    local i v=
    for ((i = ${#1} - 2; i >= 0; i -= 2)); do v+=${1:i:2}; done
    R=$((16#$v))
}

# guid HEX: a GUID's 32 hex digits from EFI byte order (the first three
# fields little-endian) to canonical order, or back, into G.
guid() { G=${1:6:2}${1:4:2}${1:2:2}${1:0:2}${1:10:2}${1:8:2}${1:14:2}${1:12:2}${1:16}; }

# bin HEX: HEX's bytes, to stdout.
bin() {
    local i e=
    for ((i = 0; i < ${#1}; i += 2)); do e+=\\x${1:i:2}; done
    printf '%b' "$e"
}

# slice OFF LEN: the LEN bytes at OFF of FILE, to stdout. dd, because in
# tail -c +N | head -c M head can quit while tail still writes, and pipefail
# fails on tail's SIGPIPE.
slice() { dd if="$file" skip="$1"B count="$2"B bs=64K status=none; }

# --- DER, as much as these files need -----------------------------------------
# B is the buffer walked, in hex, BN bytes long: the SignedData, a
# certificate, or an entry's data. tlv leaves one element in T (its tag), S
# and E (where its content starts and ends); children leaves the elements of a
# range in the arrays K, KS, KE and KH (where each header starts): Python's
# (tag, start, end, header).
buf() { B=$1 BN=$((${#1} / 2)); }

# tlv POS: the DER element at POS of B.
tlv() {
    local p=$1 n k
    ((p + 2 <= BN)) || die "DER: truncated"
    T=${B:2*p:2} n=$((16#${B:2*p+2:2})) p=$((p + 2))
    if ((n & 0x80)); then
        k=$((n & 0x7f))
        ((1 <= k && k <= 4 && p + k <= BN)) || die "DER: bad length"
        n=$((16#${B:2*p:2*k})) p=$((p + k))
    fi
    ((p + n <= BN)) || die "DER: element runs past its end"
    S=$p E=$((p + n))
}

# children START END: the elements between START and END, which they must
# fill exactly.
children() {
    local p=$1
    K=() KS=() KE=() KH=()
    while ((p < $2)); do
        tlv "$p"
        K+=("$T") KS+=("$S") KE+=("$E") KH+=("$p")
        p=$E
    done
    ((p == $2)) || die "DER: elements overrun their container"
}

# one MSG: B is one SEQUENCE and nothing else (S and E of tlv 0), or MSG.
one() {
    tlv 0
    [ "$T" = 30 ] && [ "$E" = "$BN" ] || die "$1"
}

# is I HEX: whether the content of element I (of the last children) is HEX.
is() { [ "${B:2*KS[$1]:2*(KE[$1]-KS[$1])}" = "$2" ]; }

# tlv_of I: element I (of the last children), header included.
tlv_of() { V=${B:2*KH[$1]:2*(KE[$1]-KH[$1])}; }

# alg I OID MSG: element I (of the last children) is an AlgorithmIdentifier
# of OID, or MSG. It leaves the AlgorithmIdentifier's own elements in K, KS,
# KE and KH.
alg() {
    ((${#K[@]} > $1)) || die "$3"
    children "${KS[$1]}" "${KE[$1]}"
    [ "${K[0]-}" = 06 ] || die "DER: AlgorithmIdentifier without an OID"
    is 0 "$2" || die "$3"
}

# tbs_fields N: the certificate B's tbsCertificate fields, as children, the
# optional [0] version dropped: serial, signature, issuer, validity, subject,
# key, ...; at least N of them.
tbs_fields() {
    tlv 0
    tlv "$S"
    children "$S" "$E"
    if [ "${K[0]-}" = a0 ]; then
        K=("${K[@]:1}") KS=("${KS[@]:1}") KE=("${KE[@]:1}") KH=("${KH[@]:1}")
    fi
    ((${#K[@]} >= $1)) || die "DER: a certificate without its fields"
}

# der_len N: N as a DER length, in hex, into L.
der_len() {
    printf -v L %x "$1"
    ((${#L} % 2 == 0)) || L=0$L
    (($1 < 0x80)) || printf -v L %02x%s $((0x80 | ${#L} / 2)) "$L"
}

# content_info LEN: the start of the ContentInfo openssl expects around a
# bare SignedData of LEN bytes, to stdout.
content_info() {
    local oid sd
    der_len $((${#SIGNED_DATA_OID} / 2))
    oid=06$L$SIGNED_DATA_OID
    der_len "$1"
    sd=a0$L
    der_len $((${#oid} / 2 + ${#sd} / 2 + $1))
    bin "30$L$oid$sd"
}

# cert_der PATH: a certificate file, PEM or DER, as DER in hex, into D.
cert_der() {
    local t
    hex "$1"
    # PEM, as Python reads it: the base64 between the first BEGIN line and the
    # first END line after it. Never laxer than Python, stricter only where
    # openssl never writes: ASCII alone, "=" only as the padding at the end,
    # and no padding bits set.
    if [[ $X =~ ^(0[9abcd]|20)*$BEGIN_HEX ]]; then
        [[ $X =~ ^(0[1-9a-f]|[1-7][0-9a-f])*$ ]] || die "$1: not ASCII text"
        t=$(< "$1")
        t=${t#*"$BEGIN"}
        t=$(tr -dc 'A-Za-z0-9+/=' <<< "${t%%"$END"*}")
        [[ $t =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || die "$1: not base64"
        X=$(base64 -d <<< "$t" | od -An -tx1 -v | tr -d ' \n') || die "$1: not base64"
    fi
    buf "$X"
    one "$1: not one certificate"
    D=$X
}

# --- The file -------------------------------------------------------------------
# H is the file in hex, N bytes long.

# split: the EFI_TIME (the first 16 bytes), PKCS#7 SignedData (from 40 to P)
# and signature lists (from P to the end) of an .auth file.
split() {
    local length
    ((N > 40)) || die "too short for EFI_VARIABLE_AUTHENTICATION_2"
    # WIN_CERTIFICATE_UEFI_GUID: dwLength counts its own 24-byte header.
    le "${H:32:8}"
    length=$R
    le "${H:40:4}"
    ((R == 0x0200)) || die "$(printf 'WIN_CERTIFICATE revision 0x%x, not 0x0200' "$R")"
    le "${H:44:4}"
    ((R == WIN_CERT_TYPE_EFI_GUID)) || die "$(printf 'WIN_CERTIFICATE type 0x%x, not WIN_CERT_TYPE_EFI_GUID' "$R")"
    guid "${H:48:32}"
    [ "$G" = "$CERT_TYPE_PKCS7" ] || die "CertType is not EFI_CERT_TYPE_PKCS7_GUID"
    ((24 < length && 16 + length <= N)) || die "WIN_CERTIFICATE length $length does not fit the file"
    P=$((16 + length))
}

# efi_time: EFI_TIME as 'YYYY-MM-DD HH:MM:SS', into STAMP. edk2 refuses one
# whose Pad1, Nanosecond, TimeZone, Daylight or Pad2 is set; it does not
# range-check the rest, which is checked here (sbvarsign writes the month
# 0-based).
efi_time() {
    local y=$((16#${H:2:2}${H:0:2})) mo=$((16#${H:4:2})) d=$((16#${H:6:2})) \
        h=$((16#${H:8:2})) mi=$((16#${H:10:2})) s=$((16#${H:12:2}))
    # Pad1, Nanosecond (4 bytes), TimeZone (2), Daylight and Pad2: bytes 7 to 15.
    [ "${H:14:18}" = 000000000000000000 ] || die "EFI_TIME: pad, nanosecond, time zone or daylight field set"
    ((1900 <= y && y <= 9999 && 1 <= mo && mo <= 12 && 1 <= d && d <= 31 && h < 24 && mi < 60 && s < 60)) ||
        die "EFI_TIME out of range: $y-$mo-$d $h:$mi:$s"
    printf -v STAMP '%04d-%02d-%02d %02d:%02d:%02d' "$y" "$mo" "$d" "$h" "$mi" "$s"
}

# entries: the entries of the signature lists from P on, with edk2's format
# checks (CheckSignatureListFormat): signature type ET and owner EO (GUIDs,
# canonical order), data start ES and length EL.
entries() {
    local p=$P q type size sig
    ET=() EO=() ES=() EL=()
    while ((p < N)); do
        ((N - p >= 28)) || die "signature list: truncated header"
        guid "${H:2*p:32}"
        type=$G
        le "${H:2*p+40:8}"
        ((R == 0)) || die "signature list: SignatureHeaderSize is not 0"
        le "${H:2*p+32:8}"
        size=$R
        le "${H:2*p+48:8}"
        sig=$R
        ((sig > 16 && size > 28 && p + size <= N && (size - 28) % sig == 0)) ||
            die "signature list: inconsistent sizes"
        for ((q = p + 28; q < p + size; q += sig)); do
            guid "${H:2*q:32}"
            ET+=("$type") EO+=("$G") ES+=("$((q + 16))") EL+=("$((sig - 16))")
        done
        p=$((p + size))
    done
}

# check_signed_data CERT: the PKCS#7, exactly as efitools writes it and edk2
# parses it: a bare SignedData (version 1, SHA-256, detached) of the signer's
# certificate (CERT, its DER in hex) and one SignerInfo, and nothing else, no
# CRLs, no attributes: what leaves the step that holds the keys carries
# nothing but what it should.
check_signed_data() {
    local ias issuer
    local -a ks ke
    # What an IssuerAndSerialNumber naming the signer holds: its issuer Name,
    # then its serial number.
    buf "$1"
    tbs_fields 3
    tlv_of 2
    issuer=$V
    tlv_of 0
    ias=$issuer$V
    buf "${H:80:2*(P-40)}"
    one "PKCS#7: not one DER SEQUENCE"
    children "$S" "$E"
    [ "${K[0]-}" = 02 ] || die "PKCS#7: wrapped in a ContentInfo, which firmware before edk2-stable202302 refuses"
    # edk2 reads the digest algorithm at a fixed place: a two-byte length,
    # then SHA-256's OID at byte 13 (VerifyTimeBasedPayload).
    [ "${B:2:2}" = 82 ] && [ "${B:26:18}" = "$SHA256_OID" ] || die "PKCS#7: no SHA-256 where edk2 looks for it"
    # version, digestAlgorithms, contentInfo, [0] certificates, signerInfos.
    [ "${K[*]}" = "02 31 30 a0 31" ] ||
        die "PKCS#7: not a SignedData of version, digest algorithms, content, certificates and signers alone"
    is 0 01 || die "PKCS#7: SignedData version is not 1"
    ks=("${KS[@]}") ke=("${KE[@]}")
    children "${ks[1]}" "${ke[1]}"
    ((${#K[@]} == 1)) || die "PKCS#7: digest algorithm is not SHA-256 alone"
    alg 0 "$SHA256_OID" "PKCS#7: digest algorithm is not SHA-256 alone"
    children "${ks[2]}" "${ke[2]}"
    ((${#K[@]} == 1)) || die "PKCS#7: carries its content; it must be detached"
    children "${ks[3]}" "${ke[3]}"
    ((${#K[@]} == 1)) || die "PKCS#7: the embedded certificate is not exactly the signer's"
    tlv_of 0
    [ "$V" = "$1" ] || die "PKCS#7: the embedded certificate is not exactly the signer's"
    children "${ks[4]}" "${ke[4]}"
    ((${#K[@]} == 1)) || die "PKCS#7: not exactly one signer"
    # version, issuerAndSerialNumber (the only signer identifier edk2's
    # parser knows), digestAlgorithm, signatureAlgorithm, signature.
    children "${KS[0]}" "${KE[0]}"
    [ "${K[*]}" = "02 30 30 30 04" ] ||
        die "PKCS#7: the SignerInfo has attributes, or names its signer by other than issuer and serial"
    is 0 01 || die "PKCS#7: SignerInfo version is not 1"
    is 1 "$ias" || die "PKCS#7: the SignerInfo names another certificate"
    alg 2 "$SHA256_OID" "PKCS#7: the signer's digest algorithm is not SHA-256"
}

# The signature, by the key of the signer alone (-nointern: not the
# certificates the file carries; -noverify: no chain, the key is the trust),
# over what firmware verifies: VariableName (UTF-16LE, no NUL) || VendorGuid
# || Attributes || TimeStamp || Data.
openssl_verify() {
    local i c name=
    for ((i = 0; i < ${#var}; i++)); do
        printf -v c %02x00 "'${var:i:1}"
        name+=$c
    done
    guid "${VENDOR[$var]//-/}"
    { bin "$name$G$ATTRS"; slice 0 16; slice "$P" $((N - P)); } > "$tmp/data"
    { content_info $((P - 40)); slice 40 $((P - 40)); } > "$tmp/sig.p7"
    openssl cms -verify -binary -inform DER -in "$tmp/sig.p7" -content "$tmp/data" -certfile "$signer" \
        -nointern -noverify -out /dev/null > /dev/null 2> "$tmp/err" ||
        die "signature does not verify with $signer: $(< "$tmp/err")"
}

verify() {
    local a g i found=() want=()
    efi_time
    [ "$STAMP" = "$time" ] || die "EFI_TIME $STAMP, expected $time"
    cert_der "$signer"
    check_signed_data "$D"
    openssl_verify
    entries
    for a in "${args[@]:1}"; do
        # The owner GUID, hyphenated or not, in braces or not, either case.
        g=${a%%:*} g=${g#\{} g=${g%\}} g=${g//-/}
        [[ $a == *:* && $g =~ ^[0-9A-Fa-f]{32}$ ]] || die "$a: not OWNER:CERT with OWNER a GUID"
        cert_der "${a#*:}"
        want+=("${g,,}:$D")
    done
    for i in "${!ET[@]}"; do
        [ "${ET[i]}" = "$CERT_X509" ] || die "entry $i: not an X.509 certificate"
        # edk2 takes only RSA keys from a PK or KEK X.509 entry.
        buf "${H:2*ES[i]:2*EL[i]}"
        tbs_fields 6
        children "${KS[5]}" "${KE[5]}"
        alg 0 "$RSA_OID" "entry $i: not an RSA key, which edk2 refuses"
        found+=("${EO[i]}:$B")
    done
    [ "$var" != PK ] || ((${#found[@]} == 1)) || die "PK: not exactly one certificate"
    [ "${found[*]}" = "${want[*]}" ] || die "the certificates or their owners are not the expected ones, in order"
    echo "$file: $var, $STAMP, ${#found[@]} certificate(s), signed by $signer: OK"
}

certs() {
    local i n=0
    entries
    for i in "${!ET[@]}"; do
        [ "${ET[i]}" = "$CERT_X509" ] || continue
        n=$((n + 1))
        { echo "$BEGIN"; slice "${ES[i]}" "${EL[i]}" | base64 -w 64; echo "$END"; } > "$dir/$n.pem"
    done
    ((n > 0)) || die "no X.509 certificates"
}

cmd=${1-}
(($#)) && shift
args=() var='' signer='' time=''
case $cmd in
verify)
    while (($#)); do
        case $1 in
        --var | --signer | --time)
            (($# >= 2)) || usage
            declare "${1#--}=$2"
            shift 2
            ;;
        -*) usage ;;
        *)
            args+=("$1")
            shift
            ;;
        esac
    done
    [[ $var =~ ^(PK|KEK|db)$ && -n $signer && -n $time && ${#args[@]} -ge 2 ]] || usage
    ;;
certs)
    (($# == 2)) || usage
    args=("$1") dir=$2
    ;;
*) usage ;;
esac
file=${args[0]}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
hex "$file"
H=$X N=$((${#X} / 2))
split
"$cmd"
