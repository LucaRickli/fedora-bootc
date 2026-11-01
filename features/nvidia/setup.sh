#!/usr/bin/env bash
#
# The nvidia feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ and its module are in place: early KMS,
# then its checks (the marked section at the end).
#
set -euxo pipefail

# --- Early KMS ----------------------------------------------------------------
# RPM Fusion ships omit_drivers for the nvidia modules; force them in.
# image/initramfs.sh rebuilds the initramfs after this and verifies the
# modules made it in.
sed -i 's/omit_drivers/force_drivers/' /usr/lib/dracut/dracut.conf.d/99-nvidia-dracut.conf

# --- Checks -----------------------------------------------------------------
# The akmods account kept the fixed IDs pre-install.sh gave it.
test "$(id -u akmods):$(getent group akmods | cut -d: -f3)" = 800:800
# The module sign.sh built: for the image's kernel, packaged, signed
# (with the db key, the only one the build has), and the open modules, which
# are "Dual MIT/GPL" (the closed ones are not).
KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
info=$(modinfo "/usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz")
rpm -q "kmod-nvidia-${KVER}" >/dev/null
grep -q '^signer: *[^ ]' <<<"$info"
# ... by the db key: the certificate sign.sh left for kmodtool.
test "$(modinfo -F sig_key "/usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz" | tr -d ':')" = \
    "$(openssl x509 -inform DER -in /etc/pki/akmods/certs/public_key.der -noout -serial | cut -d= -f2)"
grep -qx 'license: *Dual MIT/GPL' <<<"$info"
# Build-time only, so gone: the signing key and the open-modules pin.
test ! -e /etc/pki/akmods/private
test ! -e /etc/rpm/macros.nvidia-kmod
# Early KMS (above), and what overlay/ adds: the kargs, whose blacklist
# string RPM Fusion's nvidia-fallback.service matches verbatim, and the
# module options Wayland needs.
grep -q 'force_drivers' /usr/lib/dracut/dracut.conf.d/99-nvidia-dracut.conf
test -z "$(grep omit_drivers /usr/lib/dracut/dracut.conf.d/99-nvidia-dracut.conf)"
grep -qF '"rd.driver.blacklist=nouveau,nova_core",' /usr/lib/bootc/kargs.d/10-nvidia.toml
grep -qx 'options nvidia_drm modeset=1 fbdev=1' /usr/lib/modprobe.d/nvidia.conf
# nouveau for an NVIDIA GPU the module does not drive (older than Turing):
# RPM Fusion's udev rule starts nvidia-fallback.service for an NVIDIA GPU,
# and only for one, so a machine without one never runs it. The service
# loads nouveau when the nvidia module is not loaded, despite the blacklist.
grep -qE '^SUBSYSTEM=="pci", ATTRS\{vendor\}=="0x10de",.*ENV\{SYSTEMD_WANTS\}="nvidia-fallback\.service"' \
    /usr/lib/udev/rules.d/10-nvidia.rules
grep -qx 'ConditionKernelCommandLine=rd.driver.blacklist=nouveau,nova_core' /usr/lib/systemd/system/nvidia-fallback.service
grep -qx 'ConditionPathExists=!/sys/module/nvidia' /usr/lib/systemd/system/nvidia-fallback.service
grep -qx 'ExecStart=-/sbin/modprobe nouveau' /usr/lib/systemd/system/nvidia-fallback.service
modinfo -k "$KVER" nouveau >/dev/null
