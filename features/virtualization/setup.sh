#!/usr/bin/env bash
#
# The virtualization feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# Virtual machines (packages.txt): libvirt's QEMU and network daemons as
# Fedora's presets enable them, the default NAT network set to autostart, and
# the libvirt group in /etc/group, where the installer looks for the groups
# it gives new accounts.
for unit in virtqemud.socket virtnetworkd.socket; do
    test "$(systemctl is-enabled "$unit")" = enabled
done
test -e /etc/libvirt/qemu/networks/autostart/default.xml
grep -q '^libvirt:' /etc/group
# No BrlAPI key in the image (post-install.sh deletes what brlapi's %post
# made); every machine makes its own at boot (brlapi-keygen.service, which the
# preset enables), with what that %post uses: mcookie and the brlapi group.
rpm -q --quiet brlapi
test ! -e /etc/brlapi.key
test -x /usr/libexec/fedora-bootc/brlapi-keygen
grep -qx 'ExecStart=/usr/libexec/fedora-bootc/brlapi-keygen' /usr/lib/systemd/system/brlapi-keygen.service
grep -qx 'ConditionPathExists=!/etc/brlapi.key' /usr/lib/systemd/system/brlapi-keygen.service
test -x /usr/bin/mcookie
getent group brlapi >/dev/null
