#!/usr/bin/env bash
#
# Build and sign the sealed UKI. Runs in the `uki` tools stage of
# image/seal.Containerfile with the rechunked rootfs bind-mounted read-only at
# /target and the kernel + initramfs (moved out by `bootc container
# split-kernel-and-rootfs` in the `split` stage, mounted from that image) at
# $KERNEL_DIR/<kver>/, /kernel by default.
#
# `bootc container ukify` computes the composefs digest of /target, reads the
# kernel arguments from /target/usr/lib/bootc/kargs.d, and hands everything to
# systemd's `ukify`, with the digest sealed into the command line
# (`composefs=<digest>`); everything after `--` is passed to ukify unchanged.
# https://bootc.dev/bootc/experimental-composefs.html
#
set -euxo pipefail

KERNEL_DIR=${KERNEL_DIR:-/kernel}
kver=$(cd "$KERNEL_DIR" && echo *)
mkdir -p /out

bootc container ukify \
    --rootfs /target \
    --kernel-dir "${KERNEL_DIR}/${kver}" \
    -- \
    --output "/out/${kver}.efi" \
    --signtool sbsign \
    --secureboot-private-key /run/secrets/secureboot_key \
    --secureboot-certificate /run/secrets/secureboot_cert

sbverify --cert /run/secrets/secureboot_cert "/out/${kver}.efi"
