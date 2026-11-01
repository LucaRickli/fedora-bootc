#!/usr/bin/env bash
#
# An image's group step, the first dnf step of image/os.Containerfile's os
# stage: Fedora's updates, then the comps groups the features name
# (groups.txt), with every feature's exclude.txt kept out, then a record of
# the security advisories. The group IDs and excludes are in $CTX/groups/, one
# per line (image/features.sh).
#
# The updates come first because dnf installs nothing it finds installed
# ("already installed", even for a name in a feature's packages.txt), so a
# package of the base image (python3, openssl, the kernel) would otherwise
# stay at the version Fedora's daily rebuild of the base happened to carry,
# at times days behind a security update. With them every build has every
# stable Fedora update its dnf knows of, and it records which those are:
# every security advisory, from the same metadata (-C, the cache this step
# downloaded), for the packages installed by then. The scan before the push
# fails on one the image lacks only if it is in that record, and warns on
# one that reached Fedora's mirrors later
# (.github/actions/scan-image/advisories.sh). Not in it: the packages the
# features add; a fix one of those lacks only warns at the push, and the
# rebuild security.yml starts for it requires it.
#
# Before every feature's hooks, on purpose: a kernel update needs what one
# of them may remove (features/boot/post-install.sh).
#
set -euxo pipefail

CTX=${CTX:-/tmp/ctx}

# Arrays, so that a name with a glob character reaches dnf as written.
mapfile -t groups <"$CTX/groups/groups.txt"
mapfile -t exclude <"$CTX/groups/exclude.txt"
exclude=("${exclude[@]/#/--exclude=}")

dnf -y upgrade
if [ "${#groups[@]}" -gt 0 ]; then
    dnf -y group install "${exclude[@]}" "${groups[@]}"
fi

install -d /usr/share/fedora-bootc
dnf -q -C advisory list --security --all --repo=updates --json \
    > /usr/share/fedora-bootc/advisories-at-build.json

# --- Cleanup -----------------------------------------------------------------
# dnf's cache and log, what scriptlets leave in /var/lib/rpm-state, and
# /boot, which a bootc image ships empty (kernel, shim and GRUB updates
# write there).
dnf -y clean all
rm -rf /var/log/dnf5.log* /var/lib/rpm-state/*
find /boot -mindepth 1 -delete
