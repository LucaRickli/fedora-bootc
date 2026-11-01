#!/usr/bin/env bash
#
# Runs in the package layer, right after dnf (image/packages.sh): systemd-boot
# (packages.txt) and bootc's composefs backend replace the base image's
# bootloader and update stack, so rpm-ostree, bootupd and GRUB go.
#
# After every step that can change the kernel (image/groups.sh's upgrade, the
# package transaction), on purpose: with rpm-ostree installed a kernel update
# replaces the one kernel in /usr/lib/modules (the base sets installonlypkgs
# to nothing, so only one is ever installed, which bootc requires) and
# rebuilds its initramfs there; without it, it would write a rescue kernel
# and initramfs into /boot. So no hook that runs after this one may change
# the kernel.
set -euxo pipefail

# rpm-ostree cannot manage a composefs-backend system, and client-side kargs /
# package layering do not apply to a sealed UKI anyway.
if rpm -q --quiet rpm-ostree; then
    dnf -y remove rpm-ostree rpm-ostree-libs
fi

# bootupd has no systemd-boot support; bootc's own bootloader install is used.
if rpm -q --quiet bootupd; then
    rpm -e bootupd
fi
rm -rf /usr/lib/bootupd /usr/lib/ostree-boot

# GRUB, with rpm: shim-x64 stays (it is inert without Secure Boot) and
# requires it, and dnf refuses to break a protected package's dependencies.
mapfile -t grub_packages < <(rpm -qa --qf '%{NAME}\n' 'grub2*')
[ "${#grub_packages[@]}" -eq 0 ] || rpm -e --nodeps "${grub_packages[@]}"
