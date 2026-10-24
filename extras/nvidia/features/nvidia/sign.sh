#!/usr/bin/env bash
#
# The nvidia extra's signing step (image/sign.sh: after the package step, a
# step of its own with the Secure Boot db key and no network): builds the
# kernel module against the image's kernel with akmods, signed with the db
# key, the key that also signs systemd-boot and the UKI (one enrollment).
# The key is in place only while akmods runs and is removed however the step
# ends. setup.sh checks the module and that the key is gone;
# image/finalize.sh scans for any private key left in the image.
#
#   FLAVOR=open    NVIDIA's open kernel modules: Turing (RTX 2000/GTX 16) and newer (the default)
#   FLAVOR=closed  the legacy proprietary modules: Maxwell/Pascal/Volta (GTX 900/1000)
# (the extra build's argument, `just build nvidia closed`)
#
set -euxo pipefail

KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
MOD="/usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz"

# Left to itself RPM Fusion's nvidia-kmod.spec picks open vs. closed by running
# lspci at build time (nvidia-kmod-noopen-checks), and that probe sees the BUILD
# HOST's GPU even inside a podman build, so the choice would depend on the machine
# doing the building. Pin it with the spec's own macros instead (build-time only,
# removed again below).
case ${FLAVOR:-open} in
    open)   echo '%_with_kmod_nvidia_open 1'      > /etc/rpm/macros.nvidia-kmod ;;
    closed) echo '%_without_kmod_nvidia_detect 1' > /etc/rpm/macros.nvidia-kmod ;;
    *)      echo "FLAVOR must be 'open' or 'closed', got '$FLAVOR'" >&2; exit 1 ;;
esac

# --- Secure Boot: sign the modules with the db key (podman secrets) -----------
# kmodtool signs automatically when both files exist at these paths. It wants the
# certificate as DER; the private key can be used as-is. akmods builds as the
# unprivileged 'akmods' user (created by the akmods package), and kmodtool's
# sign step runs inside that build, so the key must be group-readable by it (this
# is what akmods' own kmodgenca does).
trap 'rm -rf /etc/pki/akmods/private' EXIT
mkdir -p /etc/pki/akmods/certs
openssl x509 -in /run/secrets/secureboot_cert -outform DER -out /etc/pki/akmods/certs/public_key.der
chmod 644 /etc/pki/akmods/certs/public_key.der
install -Dm640 -o root -g akmods /run/secrets/secureboot_key /etc/pki/akmods/private/private_key.priv

akmods --force --kernels "$KVER" --kmod nvidia
# akmods can finish without a module; the build log says why.
if ! modinfo "$MOD" >/dev/null 2>&1; then
    cat /var/cache/akmods/nvidia/*.failed.log 2>/dev/null || true
    echo "akmods did not produce $MOD" >&2; exit 1
fi
modinfo "$MOD" | grep -E '^(version|license|signer|sig_key)' || true

# Build-time only: the signing key, the open/closed pin, the build's leftovers.
rm -rf /etc/pki/akmods/private
rm -f /etc/rpm/macros.nvidia-kmod
rm -rf /var/cache/akmods /var/log/akmods /var/roothome/rpmbuild
