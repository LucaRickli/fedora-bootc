# One extra (extras/<name>/features/) on top of the OS image of
# image/base.Containerfile, for an image of its own named after it: the
# extra's packages (image/packages.sh), its signing step (image/sign.sh), its
# overlay/, then image/finalize.sh. Every extra is built by this one file;
# `just build-extra <name>` runs it, as localhost/fedora-bootc:<name>, and
# `just seal <name>` seals the result like the OS (`just build <name>` does
# both). The nvidia extra, for one: :nvidia and :nvidia-uki.
#
#   BASE_IMAGE  the OS image to build on: localhost/fedora-bootc:latest, or in
#               CI the one the base job pushed, by digest
#   EXTRA       the extra's name, its folder in extras/
#   FLAVOR      reaches the extra's sign.sh and setup.sh as $FLAVOR; empty by
#               default (nvidia: open or closed kernel modules, `just build
#               nvidia closed`)

# ARGs used in a FROM must be declared before the first FROM. `just` always
# passes BASE_IMAGE and EXTRA; the defaults only make a forgotten one fail
# loudly ("short-name overridden", "/extras/overridden/...: no such file").
ARG BASE_IMAGE=overridden

# The extra's features checked, together with the OS's (no file shipped by
# both), and sorted (image/features.sh), on the OS image itself, which has
# what the script needs. All of extras/, because a feature may be a link to
# another extra's. Then no overlay path of the extra may exist on the OS:
# an extra adds files and replaces none, not a package's and not one a
# build made (which the OS's own finalize.sh check cannot see).
FROM ${BASE_IMAGE} AS features
ARG EXTRA=overridden
COPY image/features.sh /image/
COPY features/ /features/
COPY extras/ /extras/
RUN /image/features.sh --out /out /extras/${EXTRA}/features /features \
    && taken=$(cd / && while IFS= read -r path; do \
           if [ -e "$path" ] || [ -L "$path" ]; then echo "$path"; fi; \
       done < /out/overlay-paths.txt) \
    && if [ -n "$taken" ]; then \
           echo "the OS already has these; an extra replaces none of its files:" >&2; \
           echo "$taken" >&2; exit 1; \
       fi

# Each step's part alone, so that editing an extra's files or setup does not
# rerun its package step.
FROM scratch AS ctx-packages
COPY image/packages.sh /image/
COPY --from=features /out/packages/ /features/

FROM scratch AS ctx-sign
COPY image/sign.sh /image/
COPY --from=features /out/sign/ /features/

FROM scratch AS ctx-finalize
COPY image/finalize.sh /image/
COPY --from=features /out/all/ /features/

FROM ${BASE_IMAGE} AS extra
# Its packages, with no key: no package scriptlet runs next to it.
RUN --mount=type=bind,from=ctx-packages,source=/,target=/ctx /ctx/image/packages.sh
# The one step with the Secure Boot db key (podman secrets, never a layer),
# and no network: each feature's sign.sh (nvidia builds and signs its kernel
# modules with the key that signs the UKI, one enrollment). Secret contents
# are not in the cache key; the cert's hash is, and so is FLAVOR, so a new db
# key or flavor re-signs without rerunning the package step.
ARG FLAVOR=
ARG SB_CERT_SHA256=
RUN --network=none \
    --mount=type=bind,from=ctx-sign,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    /ctx/image/sign.sh
# The extra's overlay/, after the OS's (no file shipped by both).
COPY --from=features /out/overlay/ /
# Services, the extra's setup.sh, and the image-wide checks again.
RUN --mount=type=bind,from=ctx-finalize,source=/,target=/ctx /ctx/image/finalize.sh
