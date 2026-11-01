#!/usr/bin/env bash
#
# dae, the eBPF transparent proxy, which Fedora does not package: upstream's
# own RPM from its GitHub release, at the version below. Run by
# image/builds.sh (see there); the RPM lands in $OUT/rpm and installs with
# the rest of the packages.
#
# Upstream signs nothing: the RPM has no signature, and the release only
# lists each file's digests, made in the job that made the files. So the
# RPM's SHA-256 is pinned here, read off a release that was looked at.
# Renovate bumps the version alone (it would take the .dgst file's first
# line, the MD5, for the digest), and the build then fails below until
# DAE_SHA256 is pinned anew: a look at each release before a root daemon
# with eBPF reaches the image.
#
set -euxo pipefail

# renovate: datasource=github-releases depName=daeuniverse/dae
DAE_VERSION=v2.1.1
DAE_SHA256=7f84e9b21c35846df0859ae5ab1ab957109204b34d3b5503659bd2cc94a74242

rpm=dae-linux-x86_64.rpm
mkdir -p "$OUT/rpm"
# Retried: GitHub resets connections often enough to fail builds.
curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
    -o "/tmp/$rpm" "https://github.com/daeuniverse/dae/releases/download/${DAE_VERSION}/${rpm}"
if ! echo "${DAE_SHA256}  /tmp/$rpm" | sha256sum --check --strict; then
    echo "$rpm of dae ${DAE_VERSION} is not the pinned one. After checking the release, pin its" \
        "SHA-256, $(sha256sum < "/tmp/$rpm" | cut -d' ' -f1), as DAE_SHA256 in features/dae/build.sh." >&2
    exit 1
fi
# The package's own header and payload digests, and that it is the package
# and version the pin names.
rpm -K --nosignature "/tmp/$rpm"
test "$(rpm -qp --qf '%{NAME} %{VERSION} %{ARCH}' "/tmp/$rpm")" = "dae ${DAE_VERSION#v} x86_64"
cp "/tmp/$rpm" "$OUT/rpm/"
