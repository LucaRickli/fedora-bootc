#!/usr/bin/env bash
#
# The boot feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# The boot splash: the theme kargs.d/30-quiet-boot.toml relies on (firmware
# logo, spinner, Fedora logo), and the unit that hides systemd-boot's menu.
test "$(plymouth-set-default-theme)" = bgrt
grep -qx 'ExecStart=/usr/bin/bootctl set-timeout menu-hidden' /usr/lib/systemd/system/hide-boot-menu.service
test -x /usr/bin/sbctl
test -s /etc/yum.repos.d/sbctl-copr.repo

# The Secure Boot enrollment sets (image/enroll.sh, which checked their
# signatures and contents), where bootc install looks for them. bootc aborts
# an install on anything but directories there, and copies only *.auth;
# systemd-boot needs PK.auth, KEK.auth and db.auth in each, and selects an
# entry by ID only if its name is lower case (bootctl set-oneshot).
sets=/usr/lib/bootc/install/secureboot-keys
test -z "$(find "$sets" -mindepth 1 -maxdepth 1 ! -type d)"
test "$(LC_ALL=C ls "$sets")" = "$(printf '%s\n' fedora-bootc-and-microsoft fedora-bootc-only)"
for set in "$sets"/*; do
    test "$(LC_ALL=C ls -A "$set")" = "$(printf '%s\n' KEK.auth PK.auth db.auth)"
    for f in "$set"/*; do
        test -s "$f"
    done
done
# The unit that puts them on the ESP of machines installed before, and what
# it runs with.
grep -qx 'ExecStart=/usr/libexec/fedora-bootc/secureboot-keys' /usr/lib/systemd/system/secureboot-keys.service
test -x /usr/libexec/fedora-bootc/secureboot-keys
for tool in iconv cmp mount udevadm python3; do
    command -v "$tool"
done
