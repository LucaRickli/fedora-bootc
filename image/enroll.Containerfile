# The Secure Boot enrollment sets (image/enroll.sh): PK.auth, KEK.auth and
# db.auth for each set, signed with the PK and KEK keys, in a build of their
# own: `just enroll DIR` builds the `sets` stage into DIR, and
# image/os.Containerfile copies DIR into the image (its build context
# `enroll`). In CI a job of its own signs them (build.yml).
#
# The build context is the repository root, as for image/os.Containerfile.

# What the sets are signed from besides the keys: enroll.sh, its checker and
# Microsoft's certificates (keys/microsoft/, public, the one part of keys/ in
# the build context besides cosign.pub).
FROM scratch AS ctx-enroll
COPY image/enroll.sh image/sbauth.sh /image/
COPY keys/microsoft/ /microsoft/

# The tools, a stage of their own: CI builds it before any key is on the
# runner, so the step with the keys is the only one that runs then. The same
# base as the OS image (image/os.Containerfile).
FROM quay.io/fedora/fedora-bootc:44 AS tools
RUN dnf -y install efitools openssl && dnf -y clean all

# The sets, with the PK and KEK keys (podman secrets, never in a layer),
# which reach this step and no other, with the three certificates, and with
# no network. Its context is COPYed rather than mounted, so that what it
# signs from is in the cache key: on buildah before 1.44 a RUN that only
# mounts a stage can reuse another build's layer. Secret contents are not in
# the cache key; SB_ENROLL_SHA256, the certificates' and the GUID's hash, is,
# so new keys re-sign instead of reusing files signed with the old ones.
FROM tools AS enroll
COPY --from=ctx-enroll / /ctx/
ARG SB_GUID=
ARG SB_ENROLL_SHA256=
RUN --network=none \
    --mount=type=secret,id=secureboot_pk_key \
    --mount=type=secret,id=secureboot_pk_cert \
    --mount=type=secret,id=secureboot_kek_key \
    --mount=type=secret,id=secureboot_kek_cert \
    --mount=type=secret,id=secureboot_cert \
    /ctx/image/enroll.sh

# The signed files alone: what `just enroll` exports.
FROM scratch AS sets
COPY --from=enroll /out/ /
