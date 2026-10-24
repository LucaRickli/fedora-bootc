#!/usr/bin/env bash
#
# Runs right after the nvidia extra's package transaction (image/packages.sh),
# in its layer. akmod-nvidia's %posttrans starts akmods in the background for
# the running kernel, which during a build is the build host's: with no
# headers for that one here, it gives up. Wait for it, so that nothing it
# writes lands in the layer half-done, and remove what it left, keeping the
# directories: the akmods package owns them, and sign.sh's akmods, which
# builds the module in a step of its own, writes its logs there.
set -euxo pipefail

for _ in $(seq 120); do
    pgrep -f /usr/sbin/akmods >/dev/null || break
    sleep 1
done
if pgrep -f /usr/sbin/akmods >/dev/null; then
    echo "akmods from akmod-nvidia's %posttrans is still running after 2 minutes" >&2
    exit 1
fi
find /var/cache/akmods /var/log/akmods -mindepth 1 -delete
