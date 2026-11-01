#!/usr/bin/env bash
#
# Runs before the package transaction (image/packages.sh): what the nvidia
# feature's packages.txt cannot say. RPM Fusion's repos come as release
# packages, and the module build needs the headers of exactly the image's
# kernel. sign.sh builds and signs the module, in a step of its own.
#
set -euxo pipefail

KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
REL=$(rpm -E %fedora)

# --- RPM Fusion free + nonfree ------------------------------------------------
# The release packages come from whichever mirror mirrors.rpmfusion.org
# redirects to, and dnf checks no signature on a package given by URL
# (localpkg_gpgcheck is off by default), so without more everything after,
# repo keys included, would rest on that mirror. Fedora ships RPM Fusion's
# signing keys in distribution-gpg-keys: those are imported first, and the
# two packages must be signed by them (an unsigned, tampered or differently
# signed package fails the transaction). The module build that sign.sh runs
# with the Secure Boot key comes from these repositories, which is why it
# matters most here.
# The two keys are in rpm's keyring for this check alone and deleted right
# after it, so the image's keyring is the one its packages make: dnf
# imports a repository's key from the verified release package when it
# first installs from that repository (nonfree's in the package step; free
# provides nothing the image installs).
dnf -y install distribution-gpg-keys
keys=$(rpm -qa 'gpg-pubkey*' --qf '%{VERSION}\n' | LC_ALL=C sort)
rpmkeys --import \
    "/usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-free-fedora-${REL}" \
    "/usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-nonfree-fedora-${REL}"
dnf -y install --setopt=localpkg_gpgcheck=1 \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${REL}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${REL}.noarch.rpm"
LC_ALL=C comm -13 <(printf '%s\n' "$keys") <(rpm -qa 'gpg-pubkey*' --qf '%{VERSION}\n' | LC_ALL=C sort) |
    xargs -r rpmkeys --delete

# --- Kernel headers for exactly the image's kernel ----------------------------
# fedora-bootc enables updates-archive, so this version stays installable after
# newer kernels hit the updates repo.
dnf -y install "kernel-devel-${KVER}"

# --- The akmods account, with fixed IDs ---------------------------------------
# The akmods package would create its account in the package transaction,
# which every feature shares, taking the next free system ID and shifting by
# one the IDs of the accounts created after it: they would then differ from
# those of the earlier images without the NVIDIA driver. A machine keeps its
# own /etc/passwd and /etc/group when it updates or switches images, so a
# file the image owns by a shifted ID would belong to another account there.
# Created here, before the transaction, far below the IDs the other accounts
# get (from 999 down), it leaves theirs as they were. As the package defines
# it (/usr/lib/sysusers.d/akmods.conf), with the IDs fixed.
systemd-sysusers --inline "u akmods 800 \"User is used by akmods to build akmod packages\" /var/cache/akmods/ -"
