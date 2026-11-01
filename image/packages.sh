#!/usr/bin/env bash
#
# Image build, part 1, for one image's features (image/features.sh sorts
# them). Each feature's pre-install.sh, then every package (packages.txt) in
# one transaction, then each post-install.sh. (Part 2, image/finalize.sh,
# runs after their overlay/ trees are copied in; the signing step,
# image/sign.sh, runs in between.) Runs inside `podman build`
# (image/os.Containerfile) with the package lists, hooks and repo files at
# /ctx/features.
#
set -euxo pipefail

CTX=${CTX:-/ctx}
shopt -s nullglob

# --- Before the transaction ---------------------------------------------------
# What the package list cannot say: repos that come as release packages,
# build dependencies pinned to the image's kernel (the nvidia feature).
for hook in "$CTX"/features/*/pre-install.sh; do
    "$hook"
done

# --- Packages ----------------------------------------------------------------
# The packages and excludes from the features' packages.txt and exclude.txt,
# one per line in install.txt and exclude.txt (written by image/features.sh).
# One transaction: every dnf run rewrites the rpm database, a layer's worth.
#
# Third-party packages come from the .repo files features ship in
# overlay/etc/yum.repos.d/, copied in here because the overlays arrive after
# this step; `dnf -y` imports each repo's gpgkey= on first use.
# The RPMs the features' build.sh made (image/builds.sh) are mounted at
# /run/builds.
# Arrays, so that a name with a glob character reaches dnf as written
# (nullglob would drop it).
mapfile -t install <"$CTX/features/install.txt"
mapfile -t exclude < <(sed 's/^/--exclude=/' "$CTX/features/exclude.txt")
built=(/run/builds/*.rpm)
for repo in "$CTX"/features/*/overlay/etc/yum.repos.d/*.repo; do
    cp "$repo" /etc/yum.repos.d/
done
if [ $((${#install[@]} + ${#built[@]})) -gt 0 ]; then
    dnf -y install "${exclude[@]}" "${install[@]}" "${built[@]}"
fi

# --- Within this layer --------------------------------------------------------
# What must never reach a layer of its own, such as keys a package's scriptlet
# generated for "this machine" (features/xrdp/post-install.sh).
for hook in "$CTX"/features/*/post-install.sh; do
    "$hook"
done

# --- Cleanup: keep /var free of build leftovers (bootc container lint) ------
dnf -y clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/roothome/.cache /var/tmp/* /tmp/*
