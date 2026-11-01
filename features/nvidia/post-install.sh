#!/usr/bin/env bash
#
# Runs right after the package transaction (image/packages.sh), in its layer.
# akmod-nvidia's %posttrans starts akmods in the background for the running
# kernel, which during a build is the build host's. On a host that runs
# another kernel (a CI runner) it finds no headers and gives up; on one that
# runs the image's kernel it builds and installs the module, without the
# Secure Boot key. Wait for it, so that nothing it writes lands in the layer
# half-done, then remove what it made: such a module, so that sign.sh builds
# it again, signed, and its logs and caches, keeping the directories (the
# akmods package owns them, and sign.sh's akmods writes there). The hooks run
# in feature name order, so boot's post-install.sh runs before this one,
# while akmods is still compiling; akmods installs its module only once the
# build is done, tens of seconds later, and dnf's lock would fail one of
# the two loudly if they ever met.
set -euxo pipefail

for _ in $(seq 900); do
    pgrep -f /usr/sbin/akmods >/dev/null || break
    sleep 1
done
if pgrep -f /usr/sbin/akmods >/dev/null; then
    echo "akmods from akmod-nvidia's %posttrans is still running after 15 minutes" >&2
    exit 1
fi
kver=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
if rpm -q --quiet "kmod-nvidia-${kver}"; then
    rpm -e "kmod-nvidia-${kver}"
fi
find /var/cache/akmods /var/log/akmods -mindepth 1 -delete
