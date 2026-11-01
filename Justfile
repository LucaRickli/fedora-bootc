image := "localhost/fedora-bootc"
# What qcow2, demo-user and shell take by default: the sealed OS.
tag := "latest-uki"

# The private keys (Secure Boot PK/KEK/db, cosign) live outside the checkout,
# in the layout of keys/ (PK/PK.key, KEK/KEK.key, db/db.key, cosign.key), so
# that nothing that reads the repo (a build context, an editor, an agent, a
# backup of the checkout) can read them. keys/ holds the public halves alone.
keys_dir := env("FEDORA_BOOTC_KEYS", data_directory() / "fedora-bootc/keys")

# The db key and its certificate, for the steps that sign and no other: the
# image's signing step (image/sign.sh: systemd-boot, nvidia's modules) and the
# UKI; the certificate goes to the enrollment step too, which puts it into
# db.auth.
# CI points both at files outside the checkout (a pull request's throwaway
# pair too). A file and never `--secret env=`: podman leaves an env secret
# behind in $TMPDIR (buildahNNNN) after the build, a src= one not.
sb_key := env("SECUREBOOT_KEY", keys_dir / "db/db.key")
sb_cert := env("SECUREBOOT_CERT", "keys/db/db.pem")
secrets := "--secret id=secureboot_key,src=" + sb_key + " --secret id=secureboot_cert,src=" + sb_cert
# Secret contents are not part of podman's cache key; the cert's hash is, in
# every step that signs, so a new key re-runs them instead of reusing a layer
# signed with the old one. sha256sum, so the host needs only coreutils.
sb_cert_sha := "SB_CERT_SHA256=$(sha256sum < '" + sb_cert + "' | cut -d' ' -f1)"

# The PK and KEK keys, for the one step that signs the Secure Boot
# enrollment sets (`just enroll`, image/enroll.sh), with their certificates;
# CI points them at files outside the checkout the same way (a pull request's
# at a throwaway tree). The owner GUID goes in as a build argument, and a hash
# of the three certificates and the GUID too, so that new keys re-sign the
# sets.
sb_pk_key := env("SECUREBOOT_PK_KEY", keys_dir / "PK/PK.key")
sb_pk_cert := env("SECUREBOOT_PK_CERT", "keys/PK/PK.pem")
sb_kek_key := env("SECUREBOOT_KEK_KEY", keys_dir / "KEK/KEK.key")
sb_kek_cert := env("SECUREBOOT_KEK_CERT", "keys/KEK/KEK.pem")
enroll_secrets := "--secret id=secureboot_pk_key,src=" + sb_pk_key + " --secret id=secureboot_pk_cert,src=" + sb_pk_cert + " --secret id=secureboot_kek_key,src=" + sb_kek_key + " --secret id=secureboot_kek_cert,src=" + sb_kek_cert
sb_guid := "SB_GUID=$(cat keys/GUID)"
sb_enroll_sha := "SB_ENROLL_SHA256=$(cat '" + sb_pk_cert + "' '" + sb_kek_cert + "' '" + sb_cert + "' keys/GUID | sha256sum | cut -d' ' -f1)"

default: build

# Needs sbctl, which fedora-bootc machines include (features/boot/packages.txt);
# in a Fedora toolbox, install it from the chenxiaolong/sbctl COPR.
#
# Generate the Secure Boot key tree (PK/KEK/db): keys into the key directory, certificates into keys/ (once)
keygen: _not-in-flatpak
    #!/usr/bin/env bash
    set -euo pipefail
    test ! -e keys/PK/PK.pem || { echo "keys/ already holds a key tree. For your own: git rm -r keys/GUID keys/PK keys/KEK keys/db"; exit 1; }
    test ! -e '{{keys_dir}}/PK/PK.key' || { echo "{{keys_dir}} already holds a key tree, not overwriting"; exit 1; }
    conf=$PWD/keys/sbctl.conf
    mkdir -p '{{keys_dir}}'
    # sbctl resolves the config's paths against its working directory.
    (cd '{{keys_dir}}' && sbctl create-keys --config "$conf")
    test -s '{{keys_dir}}/db/db.key'
    for k in PK KEK db; do install -Dm644 "{{keys_dir}}/$k/$k.pem" "keys/$k/$k.pem"; done
    cp '{{keys_dir}}/GUID' keys/GUID
    echo "Commit keys/GUID and keys/*/*.pem. Store {{keys_dir}}/db/db.key, PK/PK.key and KEK/KEK.key as the SECUREBOOT_PRIVATE_KEY, SECUREBOOT_PK_PRIVATE_KEY and SECUREBOOT_KEK_PRIVATE_KEY secrets of the release environment for CI (docs/fork.md), and back up {{keys_dir}}."

# The VS Code Flatpak (the devtools) never gets the private keys: it sees
# no ~/.local/share, and its $XDG_DATA_HOME, where keys_dir would point and
# the keygen recipes would write, is the app's own directory. A host shell or
# a toolbox shares the home, and its keys_dir is the host's.
_not-in-flatpak:
    @test ! -e /.flatpak-info || { echo "The signing keys ({{home_directory()}}/.local/share/fedora-bootc/keys) are kept out of the VS Code Flatpak: run this from a host shell or a toolbox."; exit 1; }

_need-keys: _not-in-flatpak
    @test -f '{{sb_key}}' || { printf '%s\n' "No Secure Boot db key at {{sb_key}} (keys/README.md)." \
        "  New keys: just keygen" \
        "  Keys kept in keys/: mkdir -p '{{keys_dir}}' && (cd keys && cp -a --parents GUID PK KEK db cosign.key '{{keys_dir}}/' && rm PK/PK.key KEK/KEK.key db/db.key cosign.key)"; exit 1; }
    @test -f '{{sb_cert}}' || { echo "No Secure Boot db certificate at {{sb_cert}}: just keygen writes it, then commit keys/*/*.pem."; exit 1; }

# What `just enroll` needs: the PK and KEK keys sign the enrollment sets.
_need-enroll-keys: _not-in-flatpak
    @for f in '{{sb_pk_key}}' '{{sb_kek_key}}'; do test -f "$f" || { echo "No Secure Boot key at $f: just enroll signs the enrollment sets with the PK and KEK keys (keys/README.md)."; exit 1; }; done
    @for f in '{{sb_pk_cert}}' '{{sb_kek_cert}}' '{{sb_cert}}' keys/GUID; do test -f "$f" || { echo "No $f: just keygen writes it, then commit keys/GUID and keys/*/*.pem."; exit 1; }; done

# The public half is committed and baked into the image, which verifies its
# own updates against it (features/updates/overlay/etc/containers/policy.json). Empty password,
# because CI passes the key by environment variable.
#
# Generate the cosign image-signing key pair: the key into the key directory, keys/cosign.pub (once)
cosign-keygen: _not-in-flatpak
    #!/usr/bin/env bash
    set -euo pipefail
    test ! -e '{{keys_dir}}/cosign.key' || { echo "{{keys_dir}}/cosign.key already exists, not overwriting"; exit 1; }
    test ! -e keys/cosign.pub || { echo "keys/cosign.pub already exists. For your own: git rm keys/cosign.pub"; exit 1; }
    mkdir -p '{{keys_dir}}'
    COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix '{{keys_dir}}/cosign'
    chmod 600 '{{keys_dir}}/cosign.key'
    mv '{{keys_dir}}/cosign.pub' keys/cosign.pub
    echo "Commit keys/cosign.pub. Store {{keys_dir}}/cosign.key as the SIGNING_SECRET secret of the release environment (docs/fork.md), and back it up."

# Uses the committed public key and no transparency log, exactly as the
# machine-side policy does.  just verify ghcr.io/lucarickli/fedora-bootc:latest
#
# Verify a pushed image's signature the way an installed machine does
verify ref:
    cosign verify --key keys/cosign.pub --insecure-ignore-tlog=true {{ref}}

# image/os.Containerfile builds the image and image/seal.Containerfile seals
# it; the local names follow the registry's tags: :latest unsealed and
# :latest-uki sealed.

# The Secure Boot enrollment sets the image carries, signed beforehand
# (`just enroll`). CI's image job passes the ones its enroll job signed, and
# `just build-image` then signs none of its own.
enroll_dir := env("ENROLL_DIR", "")

# A nested `just` sees none of this run's variable overrides, so the image
# name is handed on; everything else these recipes read comes from the
# environment (SECUREBOOT_KEY, SECUREBOOT_CERT, SECUREBOOT_PK_KEY,
# SECUREBOOT_PK_CERT, SECUREBOOT_KEK_KEY, SECUREBOOT_KEK_CERT,
# FEDORA_BOOTC_KEYS, ENROLL_DIR).
#
# Build and seal the image: :latest, :latest-uki
build: _need-keys
    #!/usr/bin/env bash
    set -euo pipefail
    j() { just image='{{image}}' "$@"; }
    j build-image
    j seal

# What the sealed image is built from, with its kernel still in place, so
# `bootc install` can deploy it the conventional way when the sealed image is
# inconvenient (rescue, a machine without the keys): every feature in one
# pass (image/os.Containerfile). The enrollment sets come from ENROLL_DIR, or
# `just enroll` signs them first.
# The only --pull=newer (Fedora's daily refresh): the seal uses
# --pull=missing, so a base republished in between cannot split an image
# from its seal.
#
# Build the image, unsealed: localhost/fedora-bootc:latest
build-image: _need-keys
    #!/usr/bin/env bash
    set -euo pipefail
    sets='{{enroll_dir}}'
    if [ -z "$sets" ]; then
        tmp=$(mktemp -d -p "${TMPDIR:-/var/tmp}" fedora-bootc-enroll.XXXXXX)
        trap 'rm -rf "$tmp"' EXIT
        sets=$tmp/sets
        just image='{{image}}' enroll "$sets"
    else
        # just runs in the checkout, not where it was called from.
        [[ $sets == /* ]] || { echo "ENROLL_DIR must be an absolute path: $sets" >&2; exit 1; }
        just _check-sets "$sets"
    fi
    # The modes the image gets, whatever the files arrived with (an artifact
    # keeps none).
    chmod -R u=rwX,go=rX "$sets"
    podman build --pull=newer {{secrets}} --build-arg "{{sb_cert_sha}}" \
        --build-context enroll="$sets" \
        -f image/os.Containerfile -t '{{image}}:latest' .

# The PK and KEK keys sign the sets in one step without network
# (image/enroll.Containerfile), which gets the db certificate for db.auth but
# not the db key. The signed files land in dir, which must not exist yet: an
# export merges into what a folder already holds. CI signs them in its enroll
# job.
#
# Sign the Secure Boot enrollment sets into a new folder
enroll dir: _need-enroll-keys
    #!/usr/bin/env bash
    set -euo pipefail
    dir=$(cd '{{invocation_directory()}}' && realpath -m -- '{{dir}}')
    test ! -e "$dir" || { echo "$dir exists: just enroll writes a new folder" >&2; exit 1; }
    # The tools first, which need no key (CI builds them before it writes the
    # keys). The build with the keys then reuses that layer and has no
    # network, so it fails rather than download anything next to them.
    podman build --pull=missing --target tools -f image/enroll.Containerfile .
    podman build --pull=never --network=none {{enroll_secrets}} --secret id=secureboot_cert,src={{sb_cert}} \
        --build-arg "{{sb_guid}}" --build-arg "{{sb_enroll_sha}}" \
        -f image/enroll.Containerfile --target sets -o type=local,dest="$dir" .
    just _check-sets "$dir"

# What `just enroll` writes, and what the image gets: <set>/PK.auth,
# KEK.auth and db.auth and nothing else, each list starting with this
# checkout's certificate (image/enroll.sh puts the image's own first).
# Checked before the sets leave the folder `just enroll` wrote (CI hands it
# on as an artifact) and before ENROLL_DIR's reach a build, so that a wrong
# folder, or sets signed before a certificate changed, fail here.
_check-sets dir:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    odd=$(cd '{{dir}}' && find . -mindepth 1 ! \( -path './*/*' -o -type d \) -o -path './*/*' ! \( -type f -regex '\./[^/]*/\(PK\|KEK\|db\)\.auth' \))
    test -z "$odd" || { printf '%s\n' "{{dir}} holds more than enrollment sets (just enroll DIR):" "$odd" >&2; exit 1; }
    body() { sed '/^-----/d' "$1" | tr -d '\r\n'; }
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    n=0
    for set in '{{dir}}'/*/; do
        for v in PK:'{{sb_pk_cert}}' KEK:'{{sb_kek_cert}}' db:'{{sb_cert}}'; do
            rm -rf "$tmp/c" && mkdir "$tmp/c"
            image/sbauth.sh certs "$set${v%%:*}.auth" "$tmp/c"
            [ "$(body "$tmp/c/1.pem")" = "$(body "${v#*:}")" ] ||
                { echo "$set${v%%:*}.auth does not enroll ${v#*:}: sign the sets again (just enroll DIR)" >&2; exit 1; }
            n=$((n + 1))
        done
    done
    test "$n" -gt 0 || { echo "{{dir}}: no enrollment set" >&2; exit 1; }

# Three steps (image/seal.Containerfile has the why): the split build, the
# rechunk as a plain `podman run` writing into a temporary directory, then
# the UKI build against the imported result. Nothing is handed over through
# the checkout. The OCI directory needs about 10 GB under
# ${TMPDIR:-/var/tmp}, so TMPDIR must not point at a small tmpfs.
#
# Seal the image into a signed UKI: localhost/fedora-bootc:latest-uki
seal src=(image + ":latest"): _need-keys
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(mktemp -d -p "${TMPDIR:-/var/tmp}" fedora-bootc-seal.XXXXXX)
    trap 'rm -rf "$out"' EXIT
    # 1. By image ID from here on: the rechunk and the UKI's kernel come from
    #    this exact image. --iidfile rather than -q, so the build is not silent.
    podman build --pull=missing --build-arg BASE_IMAGE='{{src}}' --iidfile "$out/split.iid" \
        -f image/seal.Containerfile --target split -t '{{image}}:latest-split' .
    split=$(sed 's/^sha256://' "$out/split.iid")
    # 2. chunkah sees the split image read-only and an empty directory, nothing
    #    else. SOURCE_DATE_EPOCH is the split image's creation time: the same
    #    image rechunks into the same layers, so an unchanged rebuild stays
    #    cached from here on.
    chunkah=$(podman build -q --pull=missing --build-arg BASE_IMAGE='{{src}}' \
        -f image/seal.Containerfile --target chunkah .)
    podman run --rm --pull=never --network=none --security-opt label=disable \
        --mount type=image,src="$split",dst=/chunkah -v "$out":/run/out \
        -e SOURCE_DATE_EPOCH="$(podman image inspect --format '{{{{.Created.Unix}}' "$split")" \
        "$chunkah" build --max-layers 256 \
        --prune /ostree --prune /sysroot/ostree --prune /kernel \
        --output oci:/run/out/oci
    test -f "$out/oci/index.json" || { echo "chunkah wrote no OCI layout" >&2; exit 1; }
    chunked=$(podman pull -q "oci:$out/oci")
    rm -rf "$out"
    # 3. The UKI against exactly the imported layers, then the final image.
    podman build --pull=missing {{secrets}} --build-arg "{{sb_cert_sha}}" \
        --build-context chunked="container-image://$chunked" \
        --build-context kernel="container-image://$split" \
        -f image/seal.Containerfile --target final -t '{{image}}:latest-uki' .

# chunkah writes the layers that get sealed and signed (`seal`). Its images
# are signed keyless by its own release workflow, so the digest pinned in
# image/seal.Containerfile is checked against that identity: the release
# workflow of github.com/coreos/chunkah, run for a version tag, through
# GitHub's OIDC issuer. CI runs this before every build (build.yml); locally
# it needs cosign and the network (the signature and the trust roots).
#
# Verify the pinned chunkah image's signature against its release workflow's identity
verify-chunkah:
    #!/usr/bin/env bash
    set -euo pipefail
    ref=$(awk 'toupper($1) == "FROM" && $2 ~ /chunkah/ { print $2 }' image/seal.Containerfile)
    test -n "$ref" || { echo "no chunkah FROM line in image/seal.Containerfile" >&2; exit 1; }
    cosign verify \
        --certificate-identity-regexp '^https://github\.com/coreos/chunkah/\.github/workflows/ci\.yml@refs/tags/v' \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com \
        "$ref" >/dev/null
    echo "chunkah $ref: signed by its release workflow"

# Needs no Secure Boot key: installer/live.Containerfile signs nothing.
# sys_admin + label=disable are for the Flatpak install inside the build (dbus).
#
# Build the minimal live ISO image (from the Fedora base image, not the OS)
build-live:
    podman build --pull=newer --cap-add=sys_admin --security-opt label=disable \
        -f installer/live.Containerfile -t {{image}}:live .

# Runs installer/build-iso.sh inside a Fedora container with the :live image
# mounted read-only at /rootfs. `--mount type=image` needs no export or unpack
# and works rootless, so there is no sudo and no copy into root storage. CI
# runs exactly this recipe.
#
# Build the live install ISO into output/
iso: build-live
    mkdir -p output
    podman run --rm --security-opt label=disable \
        -v "$(pwd)/installer/build-iso.sh":/src/build-iso.sh:ro \
        --mount type=image,source={{image}}:live,dst=/rootfs \
        -v "$(pwd)/output":/output \
        quay.io/fedora/fedora:latest /src/build-iso.sh

# CI's lint job runs this one as it is (needs only bash, find, grep and sed).
#
# Check every script's syntax and how the features fit together
check:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    # In the overlays, each file whose first line is a sh or bash shebang,
    # and the profile.d snippets, which have none.
    scripts=(image/*.sh installer/*.sh scripts/*.sh .github/actions/*/*.sh features/*/*.sh)
    shebang='^#!.*[/[:space:]](ba)?sh([[:space:]]|$)'
    overlays=(features/*/overlay)
    if [ "${#overlays[@]}" -gt 0 ]; then
        while IFS= read -r -d '' f; do
            first=
            IFS= read -r first <"$f" || :
            if [[ $f == */etc/profile.d/*.sh || $first =~ $shebang ]]; then scripts+=("$f"); fi
        done < <(find "${overlays[@]}" -type f -print0)
    fi
    # One at a time: `bash -n a.sh b.sh` parses only a.sh (b.sh becomes $1).
    for f in "${scripts[@]}"; do
        bash -n "$f"
    done
    # The features (no file shipped twice, hooks that can run;
    # image/features.sh).
    image/features.sh features
    # The checks below read the Containerfiles as text, as buildah does
    # without a parser directive (`# escape=` changes what continues a
    # line), and the mount options literally, so neither may be there.
    if grep -nE '^#[[:space:]]*(escape|syntax)[[:space:]]*=' image/*.Containerfile installer/*.Containerfile; then
        echo "a parser directive (above)" >&2
        exit 1
    fi
    if cat image/*.Containerfile installer/*.Containerfile | grep -oE -- '--mount=[^[:space:]]+' | grep -F '$'; then
        echo "a variable in a --mount option (above)" >&2
        exit 1
    fi
    # No RUN may mount the build context itself (a --mount without from=):
    # such a bind ignores .containerignore, so keys/ would be readable there.
    # Mount a stage or a build context. Every line counts, not only RUNs.
    if cat image/*.Containerfile installer/*.Containerfile |
        grep -oE -- '--mount=[^[:space:]]+' | grep -vE 'from=|type=secret'; then
        echo "a RUN mounts the build context (above)" >&2
        exit 1
    fi
    # The Secure Boot keys reach three scripts and no other: the db key the
    # image's signing step and the UKI, the PK and KEK keys the enrollment
    # sets. Such a RUN is its flags, then one of them and nothing else. Read
    # as one line each, comment lines dropped first (a comment inside a RUN
    # does not end it), and a backslash before trailing blanks taken as the
    # continuation buildah makes of it.
    runs=$(cat image/*.Containerfile installer/*.Containerfile | sed '/^[[:space:]]*#/d' |
        sed -e 's/\\[[:space:]]*$/\\/' | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' |
        grep -iE '^[[:space:]]*RUN[[:space:]]' || true)
    if grep -iF 'type=secret' <<<"$runs" |
        grep -viE '^[[:space:]]*RUN([[:space:]]+--[^[:space:]]+)*[[:space:]]+/ctx/image/(sign|uki|enroll)\.sh[[:space:]]*$'; then
        echo "a RUN with a Secure Boot key runs something other than sign.sh, uki.sh or enroll.sh (above)" >&2
        exit 1
    fi
    # The db key reaches its two and not the enrollment step.
    if grep -iE 'id=secureboot_key([,[:space:]]|$)' <<<"$runs" |
        grep -viE '[[:space:]]/ctx/image/(sign|uki)\.sh[[:space:]]*$'; then
        echo "a RUN other than sign.sh or uki.sh gets the db key (above)" >&2
        exit 1
    fi
    # The signing steps run each feature's sign.sh with the db key: with no
    # network, and nothing mounted but their own context (ctx-sign).
    sign_runs=$(grep -iE '[[:space:]]/ctx/image/sign\.sh[[:space:]]*$' <<<"$runs" || true)
    if [ -n "$sign_runs" ] && { grep -vE -- '[[:space:]]--network=none[[:space:]]' <<<"$sign_runs" ||
        grep -oE 'from=[^,[:space:]]+' <<<"$sign_runs" | grep -vx 'from=ctx-sign'; }; then
        echo "a signing step (sign.sh) has a network, or mounts more than ctx-sign (above)" >&2
        exit 1
    fi
    # The PK and KEK keys, which can replace the keys enrolled in every
    # machine, reach enroll.sh and nothing else, with no network and no stage
    # mounted but its own context (ctx-enroll; enroll.Containerfile copies it).
    pk_runs=$(grep -iE 'id=secureboot_(pk|kek)_' <<<"$runs" || true)
    if [ -n "$pk_runs" ] && grep -viE '[[:space:]]/ctx/image/enroll\.sh[[:space:]]*$' <<<"$pk_runs"; then
        echo "a RUN other than enroll.sh gets the PK or KEK key (above)" >&2
        exit 1
    fi
    if [ -n "$pk_runs" ] && { grep -vE -- '[[:space:]]--network=none[[:space:]]' <<<"$pk_runs" ||
        grep -oE 'from=[^,[:space:]]+' <<<"$pk_runs" | grep -vx 'from=ctx-enroll'; }; then
        echo "the RUN with the PK and KEK keys has a network, or mounts more than ctx-enroll (above)" >&2
        exit 1
    fi
    # What that step reads besides its tools is ctx-enroll alone, which its
    # stage COPYs: no other COPY or ADD in the enroll stage.
    copies=$(sed -e '/^[[:space:]]*#/d' image/enroll.Containerfile |
        sed -n '/^FROM[[:space:]].*[[:space:]]AS[[:space:]][[:space:]]*enroll[[:space:]]*$/I,/^FROM[[:space:]]/Ip' |
        grep -iE '^[[:space:]]*(COPY|ADD)[[:space:]]' || true)
    if [ "$copies" != 'COPY --from=ctx-enroll / /ctx/' ]; then
        printf '%s\n' "$copies"
        echo "the enroll stage copies in more than ctx-enroll (above)" >&2
        exit 1
    fi

# Runs the wizard's user step against a deployment built out of the installed
# image's own /etc: first the failure the shim exists for (exit 12, no home
# directory, and fisherman aborts the install), then the shim not failing.
# Rootless, about a minute. Needs `just build-live` and the image the ISO
# installs (`podman pull ghcr.io/lucarickli/fedora-bootc:latest-uki`).
# `just build-live` asserts the rest of the shim (TPM2 key, scratch, mirror)
# against the live image's /etc.
#
# Reproduce the wizard's user step, and the shim that makes it work
test-installer-useradd target="ghcr.io/lucarickli/fedora-bootc:latest-uki":
    scripts/test-installer-useradd.sh {{target}}

# Poke around inside a built image without booting it
shell tag=tag:
    podman run --rm -it {{image}}:{{tag}} /bin/bash

# bcvk boots a throwaway VM and runs the image's own `bootc install` in it,
# rootless, with the host's podman, qemu and virtiofsd. The VS Code Flatpak
# and the dev container (as a toolbox), both from the devtools, carry it and
# run it on the host; on the host itself: dnf install bcvk (Fedora).
# https://github.com/bootc-dev/bcvk
#
# The image must accept root over SSH by key: bcvk logs into its VM as root
# (hardcoded) with a key it injects as a systemd credential, so
# `PermitRootLogin no` in features/ssh/overlay/etc/ssh/sshd_config.d/ breaks this recipe,
# silently: anything that stops bcvk reaching root over SSH looks the same
# (the VM boots to the greeter, bcvk times out after 240s saying nothing).
# To see the guest, add --log-dir=journal,console=DIR below (bcvk does not
# create DIR) and read the sshd lines in journal.json; the default --output
# console shows only the SeaBIOS handoff, because the guest talks on hvc0.
#
# Each run leaves a sparse swap file the size of --disk-size in the host's
# /var/tmp, also when run from the VS Code Flatpak: bcvk makes it for the
# install VM and never removes it. With no bcvk VM running:
#   find /var/tmp -maxdepth 1 -name '.tmp*' -size +1G -user "$USER" -delete
#
# Install the image into a VM disk, output/disk.qcow2
qcow2 tag=tag:
    mkdir -p output
    bcvk to-disk --filesystem=btrfs --composefs-backend --bootloader=systemd \
        --format qcow2 --disk-size 20G {{image}}:{{tag}} output/disk.qcow2
    # bcvk returns before its install VM has shut down and released the disk,
    # so wait until the image is unlocked or `just vm` fails on the lock
    timeout 300 sh -c 'until qemu-img info output/disk.qcow2 >/dev/null 2>&1; do sleep 2; done'

# Lets `just vm` get past the greeter. The account goes on THAT DISK ONLY: it
# is written after the install, into the deployment's writable /etc and /var;
# the image, pushed tags, ISOs and machines are never touched. See
# scripts/vm-demo-user.sh for why writing there is safe.
#
# The password is a throwaway in a `wheel` account, passed on the command
# line and written to a file under output/. Treat the disk as compromised and
# never point it at hardware; `just qcow2` gives a clean one.
#
#   just qcow2 && just demo-user && just vm      # log in as demo / demo
#
# Add a throwaway login to output/disk.qcow2, and to that disk only
demo-user user="demo" password="demo" disk="output/disk.qcow2":
    test -f {{disk}} || { echo "No {{disk}}. Run 'just qcow2' first."; exit 1; }
    rm -rf output/.demo-user && mkdir -p output/.demo-user
    cp scripts/vm-demo-user.sh output/.demo-user/
    printf '%s\n%s\n' '{{user}}' '{{password}}' > output/.demo-user/params
    # A throwaway VM booted from the image itself is the cheapest root shell
    # with btrfs and shadow tooling next to the disk: no sudo, no loopback.
    bcvk ephemeral run --rm \
        --mount-disk-file {{disk}}:target \
        --bind "$(pwd)/output/.demo-user:demo" \
        --execute /run/virtiofs-mnt-demo/vm-demo-user.sh \
        {{image}}:{{tag}}
    cat output/.demo-user/result
    grep -q '^OK' output/.demo-user/result
    rm -rf output/.demo-user
    # The same disk-lock wait as in `qcow2` above.
    timeout 300 sh -c 'until qemu-img info {{disk}} >/dev/null 2>&1; do sleep 2; done'

# The host's OVMF firmware, from Fedora's edk2-ovmf: qemu runs on the host,
# and so does podman (ovmf-vars), also when a recipe runs from a toolbox or
# the VS Code Flatpak, so these are host paths. A Secure Boot CODE and its
# VARS must be the same build: the 2 MiB pair (the 4 MiB builds are qcow2).
# OVMF.stateless.fd, 4 MiB, is for a plain boot. Elsewhere, override them:
# just ovmf_bios=PATH vm
ovmf_bios := "/usr/share/edk2/ovmf/OVMF.stateless.fd"
ovmf_code := "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd"
ovmf_vars := "/usr/share/edk2/ovmf/OVMF_VARS.fd"

# ALWAYS boot-test here before touching hardware: a composefs digest problem
# shows up only at boot (dracut emergency shell). The image bakes in no users
# (the ISO wizard creates them), so reaching noctalia-greeter IS the pass; run
# `just demo-user` first to get into a session.
#
# Boot the qcow2 in a throwaway QEMU VM (-snapshot: changes are discarded)
vm:
    qemu-system-x86_64 \
        -machine q35,accel=kvm -cpu host -smp 2 -m 4096 \
        -vga virtio -display gtk,gl=on \
        -bios {{ovmf_bios}} \
        -snapshot -drive file=output/disk.qcow2,format=qcow2

# virt-fw-vars runs in a throwaway Fedora container (the host has no
# python3-virt-firmware: features/virtualization/packages.txt leaves it
# out). It gets the template, the three certificates, the GUID and output/,
# nothing else: it installs from the network.
#
# Write an OVMF variable store with the keys/ tree enrolled (Secure Boot VM)
ovmf-vars:
    mkdir -p output
    podman run --rm --security-opt label=disable \
        -v {{ovmf_vars}}:/OVMF_VARS.fd:ro \
        -v ./keys/GUID:/keys/GUID:ro \
        -v ./keys/PK/PK.pem:/keys/PK.pem:ro \
        -v ./keys/KEK/KEK.pem:/keys/KEK.pem:ro \
        -v ./keys/db/db.pem:/keys/db.pem:ro \
        -v ./output:/output \
        registry.fedoraproject.org/fedora-minimal:44 \
        sh -c 'dnf -y install python3-virt-firmware >/dev/null && virt-fw-vars \
            --input /OVMF_VARS.fd --secure-boot \
            --set-pk  "$(cat /keys/GUID)" /keys/PK.pem \
            --add-kek "$(cat /keys/GUID)" /keys/KEK.pem \
            --add-db  "$(cat /keys/GUID)" /keys/db.pem \
            -o /output/OVMF_VARS_custom.fd'

# Booting the image this way is untested with Fedora's 2 MiB OVMF pair.
#
# Boot the qcow2 with Secure Boot enforcing against the enrolled keys/ tree
vm-secureboot: ovmf-vars
    qemu-system-x86_64 \
        -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 4096 \
        -vga virtio -display gtk,gl=on \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,readonly=on,file={{ovmf_code}} \
        -drive if=pflash,format=raw,unit=1,file=output/OVMF_VARS_custom.fd \
        -snapshot -drive file=output/disk.qcow2,format=qcow2

# The enrollment a machine goes through (docs/secureboot-tpm2.md): a blank
# variable store is Setup Mode, as after clearing the keys in the firmware,
# so systemd-boot offers the enrollment sets bootc install put on the disk's
# ESP, and LoaderEntryOneShot picks one, as `bootctl set-oneshot` does. In a
# VM systemd-boot enrolls it without the countdown, reboots, and the OS starts
# with Secure Boot enforcing, under the keys the image was built with. The
# store is kept in output/OVMF_VARS_enroll.fd (the disk is not changed), and
# what it holds is listed once the VM is closed. virt-fw-vars runs in a
# throwaway Fedora container, as in ovmf-vars.
#
# Enroll a Secure Boot key set from systemd-boot in a VM in Setup Mode, then boot under it
vm-enroll set="fedora-bootc-and-microsoft":
    #!/usr/bin/env bash
    set -euo pipefail
    [[ '{{set}}' =~ ^[a-z0-9-]+$ ]] || { echo "set: a directory name of /usr/lib/bootc/install/secureboot-keys/" >&2; exit 1; }
    test -f output/disk.qcow2 || { echo "No output/disk.qcow2. Run 'just qcow2' first."; exit 1; }
    vfv() {
        podman run --rm --security-opt label=disable \
            -v {{ovmf_vars}}:/OVMF_VARS.fd:ro -v ./output:/output \
            registry.fedoraproject.org/fedora-minimal:44 \
            sh -c "dnf -y install python3-virt-firmware >/dev/null && virt-fw-vars $*"
    }
    # LoaderEntryOneShot as bootctl writes it: UTF-16LE with its NUL.
    hex=$(printf '%s' 'secure-boot-keys-{{set}}' | od -An -tx1 -v | tr -d ' \n' | sed 's/../&00/g')0000
    printf '{"version": 2, "variables": [{"name": "LoaderEntryOneShot", "guid": "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f", "attr": 7, "data": "%s"}]}\n' \
        "$hex" > output/oneshot.json
    vfv --input /OVMF_VARS.fd --set-json /output/oneshot.json --output /output/OVMF_VARS_enroll.fd
    rm output/oneshot.json
    qemu-system-x86_64 \
        -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 4096 \
        -vga virtio -display gtk,gl=on \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,readonly=on,file={{ovmf_code}} \
        -drive if=pflash,format=raw,unit=1,file=output/OVMF_VARS_enroll.fd \
        -drive file=output/disk.qcow2,format=qcow2,snapshot=on
    out=$(vfv --input /output/OVMF_VARS_enroll.fd --print --verbose)
    awk '/^name=/ { show = $1 ~ /^name=(PK|KEK|db|SecureBootEnable)$/ } show && !/^ +(sha256|hash)/' <<<"$out"
    grep -q '^name=PK ' <<<"$out" || { echo "No PK in the store: nothing was enrolled (the firmware is still in Setup Mode)." >&2; exit 1; }
    echo "Enrolled {{set}}: the firmware is in User Mode with the keys above."

# Remove build outputs
clean:
    rm -rf output
