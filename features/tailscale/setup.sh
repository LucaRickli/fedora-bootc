#!/usr/bin/env bash
#
# The tailscale feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# No Tailscale software (exclude.txt keeps the RPM out; image/finalize.sh
# checks that), only the unit and the CLI wrapper, which run podman (the
# containers feature) and its auto-update timer.
test ! -e /usr/bin/tailscaled
test -x /usr/bin/tailscale
test -x /usr/bin/podman
test -e /usr/lib/systemd/system/podman-auto-update.timer
# What quadlet makes of it at boot: tailscaled.service, which runs upstream's
# stable image, kept current by podman auto-update, with tailscaled on the
# host's network with the RPM's state file and socket and the machine's
# accounts, without Tailscale SSH, and copies the CLI to where the wrapper runs
# it from. No target wants it (the unit has no [Install]), so it stays off
# until started.
out=$(mktemp -d)
/usr/libexec/podman/quadlet -no-kmsg-log "$out" "$out" "$out"
unit=$out/tailscaled.service
exec_start=$(grep '^ExecStart=' "$unit")
for arg in '--name tailscaled ' '--label io.containers.autoupdate=registry ' '--network host ' \
    '--device /dev/net/tun ' '--cap-add net_admin ' '-v /var/lib/tailscale:/var/lib/tailscale ' \
    '-v /run/tailscale:/run/tailscale ' '-v /etc/passwd:/etc/passwd:ro ' '--env TS_DISABLE_SSH_SERVER=1 ' \
    ' ghcr.io/tailscale/tailscale:stable tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock '; do
    [[ $exec_start == *"$arg"* ]]
done
grep -qx 'Wants=podman-auto-update.timer' "$unit"
grep -qx 'RuntimeDirectory=tailscale' "$unit"
grep -qx 'ExecStartPost=-/usr/bin/podman cp tailscaled:/usr/local/bin/tailscale /run/tailscale/tailscale' "$unit"
grep -qx 'ExecStartPost=-/usr/bin/timeout 30 /usr/bin/podman exec tailscaled tailscale set --ssh=false' "$unit"
# Not part of the boot, which would wait for a pull otherwise.
grep -qx 'After=multi-user.target' "$unit"
grep -qx 'cli=/run/tailscale/tailscale' /usr/bin/tailscale
test -z "$(find "$out" -name tailscaled.service ! -path "$unit")"
rm -rf "$out"
