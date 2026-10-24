#!/usr/bin/env bash
#
# An extra's signing step, between its package step (image/packages.sh) and
# its overlay: each feature's sign.sh (nvidia builds and signs its kernel
# module). image/extra.Containerfile runs it in a step of its own, the only
# one of an extra with the Secure Boot db key (podman secrets, at
# /run/secrets/), and with no network, so neither a package scriptlet nor a
# download ever runs next to the key.
#
set -euxo pipefail

CTX=${CTX:-/ctx}
shopt -s nullglob

for hook in "$CTX"/features/*/sign.sh; do
    "$hook"
done

# What a sign.sh's own dnf runs leave behind (akmods installs the module it
# built with one), out of the layer.
dnf -y clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/roothome/.cache /var/tmp/* /tmp/*
