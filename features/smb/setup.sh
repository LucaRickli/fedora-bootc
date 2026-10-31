#!/usr/bin/env bash
#
# The smb feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# gvfs's SMB backend, for the file manager the desktop feature installs.
test -x /usr/libexec/gvfsd-smb
test -f /usr/share/gvfs/mounts/smb.mount
rpm -q nautilus >/dev/null
test -x /usr/sbin/mount.cifs
test -x /usr/bin/smbclient
# Client only: no Samba server.
test -z "$(rpm -qa samba)"
