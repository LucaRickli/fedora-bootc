#!/usr/bin/env bash
#
# The boot feature's signing step (image/sign.sh: after the package step, a
# step of its own with the Secure Boot db key and no network): systemd-boot,
# signed in place. `bootc install` copies it from /usr/lib/systemd/boot/efi/
# into the ESP, so the signature must exist here, before the seal computes
# the composefs digest over /usr.
#
set -euxo pipefail

efi=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
sbsign --key /run/secrets/secureboot_key --cert /run/secrets/secureboot_cert --output "$efi" "$efi"
sbverify --cert /run/secrets/secureboot_cert "$efi"
