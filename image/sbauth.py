#!/usr/bin/env python3
#
# Reads a Secure Boot enrollment file (PK.auth, KEK.auth or db.auth: an
# EFI_VARIABLE_AUTHENTICATION_2 followed by the variable's
# EFI_SIGNATURE_LISTs, UEFI 2.10 sections 8.2.2 and 32.4.1) and checks it the
# way systemd-boot writes it and edk2 accepts it. The standard library and the
# openssl command only. image/enroll.sh checks every file it signs with it;
# image/uki-trust.sh lists a db.auth's certificates with it.
#
#   sbauth.py verify FILE --var NAME --signer CERT --time 'YYYY-MM-DD HH:MM:SS' OWNER:CERT...
#       FILE is the variable NAME (PK, KEK or db), signed by CERT's key over
#       the attributes systemd-boot writes it with, stamped with that time
#       (UTC), and holds exactly these certificates (PEM or DER), each with
#       its owner GUID, in this order.
#   sbauth.py certs FILE DIR
#       every X.509 certificate of FILE's signature lists, as DIR/<n>.pem
#
# The checks follow edk2 (SecurityPkg/Library/AuthVariableLib/AuthService.c),
# where a file that fails them is refused by the firmware, except that this is
# stricter where firmware differs: older edk2 (before edk2-stable202302)
# refuses a PKCS#7 wrapped in a ContentInfo, so only the bare SignedData that
# efitools writes passes here.
#
import argparse
import base64
import os
import struct
import subprocess
import sys
import tempfile
import uuid

# The vendor GUID is part of what is signed, and is in no file: systemd-boot
# passes the one of the variable's name to SetVariable().
VENDOR = {
    "PK": uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c"),  # EFI_GLOBAL_VARIABLE
    "KEK": uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c"),
    "db": uuid.UUID("d719b2cb-3d3a-4596-a3bc-dad00e67656f"),  # EFI_IMAGE_SECURITY_DATABASE_GUID
}
# NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS |
# TIME_BASED_AUTHENTICATED_WRITE_ACCESS: what systemd-boot writes each
# variable with (src/boot/secure-boot.c), and so what the signature covers.
ATTRS = 0x27
CERT_TYPE_PKCS7 = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7")  # EFI_CERT_TYPE_PKCS7_GUID
CERT_X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")  # EFI_CERT_X509_GUID
WIN_CERT_TYPE_EFI_GUID = 0x0EF1
SHA256_OID = bytes.fromhex("608648016503040201")  # 2.16.840.1.101.3.4.2.1
RSA_OID = bytes.fromhex("2a864886f70d010101")  # 1.2.840.113549.1.1.1
SIGNED_DATA_OID = bytes.fromhex("2a864886f70d010702")  # 1.2.840.113549.1.7.2


class Invalid(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Invalid(msg)


# --- DER, as much as these files need -----------------------------------------
def tlv(buf, pos):
    """The DER element at pos: (tag, content start, content end)."""
    check(pos + 2 <= len(buf), "DER: truncated")
    tag, n = buf[pos], buf[pos + 1]
    pos += 2
    if n & 0x80:
        k = n & 0x7F
        check(1 <= k <= 4 and pos + k <= len(buf), "DER: bad length")
        n = int.from_bytes(buf[pos : pos + k], "big")
        pos += k
    check(pos + n <= len(buf), "DER: element runs past its end")
    return tag, pos, pos + n


def children(buf, start, end):
    """The elements between start and end: [(tag, start, end, header start)]."""
    out = []
    pos = start
    while pos < end:
        tag, s, e = tlv(buf, pos)
        out.append((tag, s, e, pos))
        pos = e
    check(pos == end, "DER: elements overrun their container")
    return out


def der_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def content_info(signed_data):
    """The bare SignedData in the ContentInfo openssl expects."""
    body = b"\x06" + der_len(len(SIGNED_DATA_OID)) + SIGNED_DATA_OID
    body += b"\xa0" + der_len(len(signed_data)) + signed_data
    return b"\x30" + der_len(len(body)) + body


def cert_der(path):
    """A certificate file, PEM or DER, as DER."""
    with open(path, "rb") as f:
        data = f.read()
    if data.lstrip().startswith(b"-----BEGIN CERTIFICATE-----"):
        lines = data.decode().split("-----BEGIN CERTIFICATE-----", 1)[1]
        lines = lines.split("-----END CERTIFICATE-----", 1)[0]
        data = base64.b64decode("".join(lines.split()))
    tag, _, end = tlv(data, 0)
    check(tag == 0x30 and end == len(data), f"{path}: not one certificate")
    return data


def tbs_fields(der):
    """A certificate's tbsCertificate fields, the optional [0] version
    dropped: serial, signature, issuer, validity, subject, key, ..."""
    _, s, _ = tlv(der, 0)
    fields = children(der, *tlv(der, s)[1:])
    return fields[1:] if fields[0][0] == 0xA0 else fields


def alg_oid(buf, alg):
    """The OID of an AlgorithmIdentifier element."""
    oid = children(buf, alg[1], alg[2])[0]
    check(oid[0] == 0x06, "DER: AlgorithmIdentifier without an OID")
    return buf[oid[1] : oid[2]]


def cert_is_rsa(der):
    """edk2 takes only RSA keys from a PK or KEK X.509 entry."""
    spki = tbs_fields(der)[5]
    return alg_oid(der, children(der, spki[1], spki[2])[0]) == RSA_OID


def issuer_and_serial(der):
    """What an IssuerAndSerialNumber naming this certificate holds: its
    issuer Name, then its serial number."""
    serial, _, issuer = tbs_fields(der)[:3]
    return der[issuer[3] : issuer[2]] + der[serial[3] : serial[2]]


def pem(der):
    b64 = base64.b64encode(der).decode()
    body = "\n".join(b64[i : i + 64] for i in range(0, len(b64), 64))
    return f"-----BEGIN CERTIFICATE-----\n{body}\n-----END CERTIFICATE-----\n"


# --- The file -------------------------------------------------------------------
def split(data):
    """(EFI_TIME, PKCS#7 SignedData, signature lists) of an .auth file."""
    check(len(data) > 40, "too short for EFI_VARIABLE_AUTHENTICATION_2")
    # WIN_CERTIFICATE_UEFI_GUID: dwLength counts its own 24-byte header.
    length, revision, cert_type = struct.unpack_from("<IHH", data, 16)
    check(revision == 0x0200, f"WIN_CERTIFICATE revision {revision:#x}, not 0x0200")
    check(cert_type == WIN_CERT_TYPE_EFI_GUID, f"WIN_CERTIFICATE type {cert_type:#x}, not WIN_CERT_TYPE_EFI_GUID")
    check(uuid.UUID(bytes_le=data[24:40]) == CERT_TYPE_PKCS7, "CertType is not EFI_CERT_TYPE_PKCS7_GUID")
    check(24 < length and 16 + length <= len(data), f"WIN_CERTIFICATE length {length} does not fit the file")
    return data[:16], data[40 : 16 + length], data[16 + length :]


def efi_time(raw):
    """EFI_TIME as 'YYYY-MM-DD HH:MM:SS'. edk2 refuses one whose Pad1,
    Nanosecond, TimeZone, Daylight or Pad2 is set; it does not range-check the
    rest, which is checked here (sbvarsign writes the month 0-based)."""
    y, mo, d, h, mi, s, pad1, ns, tz, dl, pad2 = struct.unpack("<HBBBBBBIhBB", raw)
    check((pad1, ns, tz, dl, pad2) == (0, 0, 0, 0, 0), "EFI_TIME: pad, nanosecond, time zone or daylight field set")
    check(1900 <= y <= 9999 and 1 <= mo <= 12 and 1 <= d <= 31 and h < 24 and mi < 60 and s < 60,
          f"EFI_TIME out of range: {y}-{mo}-{d} {h}:{mi}:{s}")
    return f"{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}"


def entries(esl):
    """[(signature type, owner, data)] of a list of EFI_SIGNATURE_LISTs, with
    edk2's format checks (CheckSignatureListFormat)."""
    out = []
    pos = 0
    while pos < len(esl):
        check(len(esl) - pos >= 28, "signature list: truncated header")
        stype = uuid.UUID(bytes_le=esl[pos : pos + 16])
        list_size, header_size, sig_size = struct.unpack_from("<III", esl, pos + 16)
        check(header_size == 0, "signature list: SignatureHeaderSize is not 0")
        check(sig_size > 16 and list_size > 28 and pos + list_size <= len(esl)
              and (list_size - 28) % sig_size == 0, "signature list: inconsistent sizes")
        for p in range(pos + 28, pos + list_size, sig_size):
            out.append((stype, uuid.UUID(bytes_le=esl[p : p + 16]), esl[p + 16 : p + sig_size]))
        pos += list_size
    return out


def check_signed_data(sig, signer):
    """The PKCS#7, exactly as efitools writes it and edk2 parses it: a bare
    SignedData (version 1, SHA-256, detached) of the signer's certificate and
    one SignerInfo, and nothing else, no CRLs, no attributes: what leaves the
    step that holds the keys carries nothing but what it should."""
    tag, s, e = tlv(sig, 0)
    check(tag == 0x30 and e == len(sig), "PKCS#7: not one DER SEQUENCE")
    items = children(sig, s, e)
    check(items[0][0] == 0x02, "PKCS#7: wrapped in a ContentInfo, which firmware before edk2-stable202302 refuses")
    # edk2 reads the digest algorithm at a fixed place: a two-byte length,
    # then SHA-256's OID at byte 13 (VerifyTimeBasedPayload).
    check(sig[1] == 0x82 and sig[13:22] == SHA256_OID, "PKCS#7: no SHA-256 where edk2 looks for it")
    # version, digestAlgorithms, contentInfo, [0] certificates, signerInfos.
    check([i[0] for i in items] == [0x02, 0x31, 0x30, 0xA0, 0x31],
          "PKCS#7: not a SignedData of version, digest algorithms, content, certificates and signers alone")
    check(sig[items[0][1] : items[0][2]] == b"\x01", "PKCS#7: SignedData version is not 1")
    algs = children(sig, items[1][1], items[1][2])
    check(len(algs) == 1 and alg_oid(sig, algs[0]) == SHA256_OID, "PKCS#7: digest algorithm is not SHA-256 alone")
    check(len(children(sig, items[2][1], items[2][2])) == 1, "PKCS#7: carries its content; it must be detached")
    embedded = [sig[c[3] : c[2]] for c in children(sig, items[3][1], items[3][2])]
    check(embedded == [signer], "PKCS#7: the embedded certificate is not exactly the signer's")
    infos = children(sig, items[4][1], items[4][2])
    check(len(infos) == 1, "PKCS#7: not exactly one signer")
    # version, issuerAndSerialNumber (the only signer identifier edk2's
    # parser knows), digestAlgorithm, signatureAlgorithm, signature.
    info = children(sig, infos[0][1], infos[0][2])
    check([i[0] for i in info] == [0x02, 0x30, 0x30, 0x30, 0x04],
          "PKCS#7: the SignerInfo has attributes, or names its signer by other than issuer and serial")
    check(sig[info[0][1] : info[0][2]] == b"\x01", "PKCS#7: SignerInfo version is not 1")
    check(sig[info[1][1] : info[1][2]] == issuer_and_serial(signer), "PKCS#7: the SignerInfo names another certificate")
    check(alg_oid(sig, info[2]) == SHA256_OID, "PKCS#7: the signer's digest algorithm is not SHA-256")


def openssl_verify(signed_data, content, signer_path):
    """The signature, by the key of signer_path alone (-nointern: not the
    certificates the file carries; -noverify: no chain, the key is the
    trust), over content."""
    with tempfile.TemporaryDirectory() as d:
        p7, data = os.path.join(d, "sig.p7"), os.path.join(d, "data")
        with open(p7, "wb") as f:
            f.write(content_info(signed_data))
        with open(data, "wb") as f:
            f.write(content)
        r = subprocess.run(
            ["openssl", "cms", "-verify", "-binary", "-inform", "DER", "-in", p7, "-content", data,
             "-certfile", signer_path, "-nointern", "-noverify", "-out", os.devnull],
            capture_output=True, text=True)
    check(r.returncode == 0, f"signature does not verify with {signer_path}: {r.stderr.strip()}")


def verify(path, var, signer_path, time, expected):
    with open(path, "rb") as f:
        data = f.read()
    raw_time, signed_data, payload = split(data)
    stamp = efi_time(raw_time)
    check(stamp == time, f"EFI_TIME {stamp}, expected {time}")
    signer = cert_der(signer_path)
    check_signed_data(signed_data, signer)
    # What firmware verifies: VariableName (UTF-16LE, no NUL) || VendorGuid ||
    # Attributes || TimeStamp || Data.
    tbs = var.encode("utf-16-le") + VENDOR[var].bytes_le + struct.pack("<I", ATTRS) + raw_time + payload
    openssl_verify(signed_data, tbs, signer_path)
    found = entries(payload)
    want = [(CERT_X509, uuid.UUID(owner), cert_der(cert)) for owner, cert in expected]
    for i, (stype, owner, der) in enumerate(found):
        check(stype == CERT_X509, f"entry {i}: not an X.509 certificate")
        check(cert_is_rsa(der), f"entry {i}: not an RSA key, which edk2 refuses")
    check(var != "PK" or len(found) == 1, "PK: not exactly one certificate")
    check(found == want, "the certificates or their owners are not the expected ones, in order")
    print(f"{path}: {var}, {stamp}, {len(found)} certificate(s), signed by {signer_path}: OK")


def certs(path, outdir):
    with open(path, "rb") as f:
        _, _, payload = split(f.read())
    n = 0
    for stype, _, der in entries(payload):
        if stype == CERT_X509:
            n += 1
            with open(os.path.join(outdir, f"{n}.pem"), "w") as f:
                f.write(pem(der))
    check(n > 0, "no X.509 certificates")


def main():
    p = argparse.ArgumentParser(description="Check a Secure Boot enrollment file (.auth).")
    sub = p.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verify")
    v.add_argument("file")
    v.add_argument("--var", required=True, choices=sorted(VENDOR))
    v.add_argument("--signer", required=True)
    v.add_argument("--time", required=True)
    v.add_argument("entries", nargs="+", metavar="OWNER:CERT")
    c = sub.add_parser("certs")
    c.add_argument("file")
    c.add_argument("dir")
    a = p.parse_args()
    try:
        if a.cmd == "verify":
            verify(a.file, a.var, a.signer, a.time, [e.split(":", 1) for e in a.entries])
        else:
            certs(a.file, a.dir)
    except (Invalid, OSError, ValueError) as e:
        sys.exit(f"{a.file}: {e}")


if __name__ == "__main__":
    main()
