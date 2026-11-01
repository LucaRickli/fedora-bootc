#!/usr/bin/env bash
#
# The dae feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# dae (build.sh's RPM), its unit and the routing data it reads, and off: no
# configuration, and the unit disabled (the preset; image/finalize.sh checks
# its state), so it does nothing until a machine is given both.
rpm -q dae >/dev/null
test -x /usr/bin/dae
test -s /usr/share/dae/geoip.dat
test -s /usr/share/dae/geosite.dat
grep -qx 'ExecStart=/usr/bin/dae run --disable-timestamp -c /etc/dae/config.dae' /usr/lib/systemd/system/dae.service
test ! -e /etc/dae/config.dae
