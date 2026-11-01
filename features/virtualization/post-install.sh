#!/usr/bin/env bash
#
# Runs in the package layer, right after dnf (image/packages.sh): brlapi,
# which QEMU's braille device pulls in (qemu-char-baum), creates
# /etc/brlapi.key in its %post when it is missing, the key BrlAPI clients
# authenticate to a braille display server (brltty) with. Here that is at
# image build time, so every machine would share one, published with the
# image. Deleted in this same RUN, so it never reaches a layer; each machine
# generates its own at boot (overlay/usr/libexec/fedora-bootc/brlapi-keygen).
set -euxo pipefail

rm -f /etc/brlapi.key
