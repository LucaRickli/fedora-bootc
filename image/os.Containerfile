# The OS image, unsealed and with its kernel still in place: every feature of
# features/, an ordinary bootc image in its own right. `just build-image`
# builds it as localhost/fedora-bootc:latest, and image/seal.Containerfile
# seals it into a signed UKI carrying the composefs digest of its rootfs
# (latest-uki; `just build` does both). Pattern:
# https://bootc.dev/bootc/experimental-composefs.html and
# https://github.com/travier/fedora-atomic-desktops-sealed
#
# The build context is the repository root; .containerignore keeps keys/ out
# of it, and no step mounts the context itself, so a RUN sees only what a
# stage below COPYed first. The Secure Boot enrollment sets come from the
# build context `enroll` (image/enroll.Containerfile's output, which the
# Justfile passes).
#
# ALWAYS boot-test a build in a VM (`just qcow2 && just vm`) before installing
# or upgrading real hardware: a build/install digest mismatch only shows up at
# boot, as a dracut emergency shell.

# One base for the OS image and the build stages. It floats on the release
# tag; moving to the next Fedora release is a deliberate edit here, in
# image/enroll.Containerfile, image/seal.Containerfile and
# installer/live.Containerfile (the live ISO's system).
FROM quay.io/fedora/fedora-bootc:44 AS base

# The parts of the repo the build scripts read, each in a stage that one step
# below mounts (copies, for the group step). Only what each step needs, so
# that editing docs or CI files does not invalidate the cached package layer.
#
# image/features.sh checks the features (no file shipped twice, scripts that
# can run) and sorts them: the group and package steps' files apart from the
# rest, so that editing a feature's files or setup does not re-run them. COPY
# cannot pick files like that, hence the stage, on the base image, which has
# everything the script uses.
FROM base AS features
COPY image/features.sh /image/
COPY features/ /features/
RUN /image/features.sh --out /out /features

# The group step's part, COPYed into that step rather than mounted: on
# buildah before 1.44 a RUN that only mounts a stage can reuse another build's
# layer once that stage comes from cache, while what a COPY brings is in the
# cache key. The step every later one builds on stays out of that hazard.
FROM scratch AS ctx-groups
COPY image/groups.sh /image/
COPY --from=features /out/groups/ /groups/

FROM scratch AS ctx
COPY image/packages.sh /image/
COPY --from=features /out/packages/ /features/

FROM scratch AS ctx-builds
COPY image/builds.sh /image/
COPY --from=features /out/builds/ /builds/

# The signing step's part alone: the stage is mounted into the OS at that
# step, so anything else in it would re-run that step and all that follows.
FROM scratch AS ctx-sign
COPY image/sign.sh /image/
COPY --from=features /out/sign/ /features/

# What Fedora does not package (noctalia-greeter, shimmy, ...): every
# feature's build.sh, run by image/builds.sh. From the same base as
# the image, so it links against the libraries the image ships and a base
# update rebuilds it; a stage of its own, so no toolchain reaches the image.
# Adding or changing a build needs no edit here.
#
# Fedora's updates first, as the OS below applies them, so the builds link
# against the libraries the image ships. A dnf run of its own, minutes from
# the OS's in the same build: an update that lands in between is the rare
# case where the two differ, accepted, since the package step installs the
# built RPMs with dnf, which brings in any newer library they require.
FROM base AS builds
RUN dnf -y upgrade && dnf -y clean all
RUN --mount=type=bind,from=ctx-builds,source=/,target=/ctx /ctx/image/builds.sh

# The built RPMs alone, for the package step: COPY hashes content, so a build
# that only changed files leaves the package layer cached.
FROM scratch AS built-rpms
COPY --from=builds /out/rpm/ /

# finalize.sh's context, here because it lists what the builds made, to
# check against every feature's overlay paths.
FROM scratch AS ctx-finalize
COPY image/finalize.sh /image/
COPY --from=features /out/all/ /features/
COPY --from=features /out/overlay-paths.txt /
COPY --from=features /out/excluded.txt /
COPY --from=builds /out/root-paths.txt /

FROM base AS os

# The rootfiles package pulled in below expects root's home directory to
# exist at build time (on a booted system systemd creates it under /var).
RUN mkdir -p /var/roothome

# Fedora's updates, then the comps groups the features name (groups.txt):
# image/groups.sh, which also records the security advisories for the scan.
# Its own step, so that a change to a feature's packages does not rebuild
# these GBs. COPYed in rather than mounted (ctx-groups, above), and deleted
# by the same RUN.
COPY --from=ctx-groups / /tmp/ctx/
RUN /tmp/ctx/image/groups.sh && rm -rf /tmp/ctx

# Every feature's packages (packages.txt, plus the RPMs the builds made),
# with each feature's pre- and post-install.sh. The expensive layer: nothing
# below invalidates it.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=built-rpms,source=/,target=/run/builds \
    /ctx/image/packages.sh

# Each feature's sign.sh (image/sign.sh; the boot feature's signs
# systemd-boot, nvidia's builds and signs its kernel modules), with the
# Secure Boot db key (podman secrets, so the private key never enters a
# layer) and no network. Secret contents are not in the cache key; the cert's
# hash is, so a new db key re-signs instead of reusing what was signed before.
ARG SB_CERT_SHA256=
RUN --network=none \
    --mount=type=bind,from=ctx-sign,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    /ctx/image/sign.sh

# Every feature's overlay/ lands verbatim on the image (no two may ship
# the same path, image/features.sh).
COPY --from=features /out/overlay/ /
# The files the builds made (shimmy, ...); none may also be in an overlay/
# (image/finalize.sh checks).
COPY --from=builds /out/root/ /

# The cosign PUBLIC key: the signature policy (features/updates/) requires a
# valid signature by it for every pull from ghcr.io/lucarickli/fedora-bootc,
# so the machine verifies its own updates. CI signs after the push
# (build.yml).
COPY keys/cosign.pub /etc/pki/containers/fedora-bootc.pub

# The Secure Boot enrollment sets (the build context `enroll`, never a
# stage), where `bootc install` finds them: it copies each <set>/*.auth to
# the ESP's loader/keys/<set>/, and systemd-boot offers "Enroll Secure Boot
# keys: <set>" while the firmware is in Setup Mode (docs/secureboot-tpm2.md).
COPY --from=enroll / /usr/lib/bootc/install/secureboot-keys/

# Services, each feature's setup.sh, and the image-wide checks.
RUN --mount=type=bind,from=ctx-finalize,source=/,target=/ctx /ctx/image/finalize.sh
