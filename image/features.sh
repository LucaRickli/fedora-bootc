#!/usr/bin/env bash
#
# The features of one image, checked, and sorted into what each build step
# reads: the OS's (features/) or an extra's (extras/<name>/features/), which
# is checked together with the OS's it is built on. Run by the `features`
# stage of image/base.Containerfile and image/extra.Containerfile, and by
# `just check`.
#
#   features.sh DIR [BELOW]             check DIR's features
#   features.sh --out OUT DIR [BELOW]   check, then sort them into OUT
#
# BELOW, for an extra, is features/: the extra may ship no file the OS ships.
# A feature is a folder. In an extra it may be a symlink to a feature of
# another extra, which makes an image that combines extras. Its files, each
# optional:
#
#   packages.txt     RPMs to install, one per line; # starts a comment
#   exclude.txt      RPMs kept out (weak dependencies that would only
#                    duplicate another), the same way
#   pre-install.sh   before the dnf transaction: what packages.txt cannot say
#   post-install.sh  right after it, in its layer
#   build.sh         the OS only: builds what Fedora does not package, from
#                    the files next to it, in a throwaway stage (builds.sh)
#   sign.sh          an extra only: a step of its own, with the Secure Boot db
#                    key and no network (sign.sh)
#   overlay/         files copied verbatim onto /
#   setup.sh         once everything is in place: setup, then the checks that
#                    prove it (finalize.sh)
#
# OUT gets each build step's part, so that editing a feature's files or setup
# does not rerun a package step:
#
#   OUT/packages/          install.txt and exclude.txt, one name per line, and
#                          per feature its pre-/post-install.sh and .repo files
#   OUT/sign/<feature>/    its sign.sh
#   OUT/all/<feature>/     the whole feature, for finalize.sh
#   OUT/overlay/           every overlay/, merged
#   OUT/builds/<feature>/  its build.sh and the files next to it
#   OUT/overlay-paths.txt  every overlay path, for finalize.sh to check the
#                          builds against
set -euo pipefail
shopt -s nullglob

usage='usage: features.sh [--out OUT] DIR [BELOW]'
out=''
if [ "${1:-}" = --out ]; then
    out=$(realpath -m "${2:?$usage}")
    shift 2
fi
dir=$(realpath "${1:?$usage}")
below=''
if [ -n "${2:-}" ]; then below=$(realpath "$2"); fi

errors=()
err() { errors+=("$*"); }

# The features of a directory: its folders and its links to folders (a file
# such as README.md is none). Each as NAME<tab>REAL PATH.
features() {
    local f
    for f in "$1"/*; do
        if [ -L "$f" ] || [ -d "$f" ]; then printf '%s\t%s\n' "${f##*/}" "$(realpath -m "$f")"; fi
    done
}

# The names in packages.txt or exclude.txt: comments and blank lines aside,
# each on a line of its own even when the file lacks a final newline (the
# lists of all features are appended into one).
names() { { cat "$1"; echo; } | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'; }

# Every overlay path of every feature in each directory, as it lands on /.
# Symlinks inside an overlay are files to ship, never followed.
overlay_paths() {
    local d name src
    for d in "$@"; do
        while IFS=$'\t' read -r name src; do
            if [ -d "$src/overlay" ]; then
                (cd "$src/overlay" && find . \( -type f -o -type l \) -printf '%P\n')
            fi
        done < <(features "$d")
    done | LC_ALL=C sort
}

known=' packages.txt exclude.txt pre-install.sh post-install.sh build.sh sign.sh overlay setup.sh '
extras=$(realpath -m "$dir/../..")
n=0
declare -A seen=()
while IFS=$'\t' read -r name src; do
    n=$((n + 1))
    # Two entries for one folder would run its hooks twice.
    if [ -n "${seen[$src]:-}" ]; then err "$name: the same feature as ${seen[$src]}"; fi
    seen[$src]=$name
    case $name in
        *[!a-z0-9-]*) err "feature names are lower-case letters, digits and -: $name" ;;
    esac
    if [ -L "$dir/$name" ]; then
        if [ -z "$below" ]; then
            err "$name: the OS's features are folders, not links"
        elif [ ! -d "$src" ]; then
            err "$name: a link that leads to no folder"
            continue
        else
            # A feature of another extra, never one of the OS's (which the
            # image already has) or something outside the repository.
            if [[ ! $src =~ ^"$extras"/[^/]+/features/[^/]+$ || $src == "$dir"/* ]]; then
                err "$name: links to $src, not to a feature of another extra"
            fi
        fi
    fi
    for entry in "$src"/*; do
        file=${entry##*/}
        # A build's own files sit next to its build.sh (a spec, a patch).
        if [[ $known != *" $file "* ]] && [ ! -e "$src/build.sh" ]; then
            allowed=${known# }
            err "$name/$file: not a feature file (${allowed% })"
        fi
    done
    for script in pre-install.sh post-install.sh build.sh sign.sh setup.sh; do
        if [ -e "$src/$script" ] && [ ! -x "$src/$script" ]; then err "$name/$script is not executable"; fi
    done
    for list in packages.txt exclude.txt; do
        if [ -e "$src/$list" ] && names "$src/$list" | grep -q '[[:space:]]'; then
            err "$name/$list: one package per line"
        fi
    done
    if [ -z "$below" ] && [ -e "$src/sign.sh" ]; then
        err "$name/sign.sh: only an extra signs in a step of its own (the OS signs in image/bootloader.sh)"
    fi
    if [ -n "$below" ] && [ -e "$src/build.sh" ]; then
        err "$name/build.sh: only the OS's features build (image/builds.sh)"
    fi
done < <(features "$dir")
[ "$n" -gt 0 ] || err "$dir has no features"

# No two features of the image ship the same file: the overlays are copied
# onto / one after the other, and the last would silently win.
while read -r path; do
    err "shipped by more than one feature: $path"
done < <(overlay_paths "$dir" ${below:+"$below"} | uniq -d)

if [ ${#errors[@]} -gt 0 ]; then
    printf '%s\n' "${errors[@]}" >&2
    exit 1
fi
[ -n "$out" ] || exit 0

mkdir -p "$out/packages" "$out/sign" "$out/all" "$out/overlay" "$out/builds"
: >"$out/packages/install.txt"
: >"$out/packages/exclude.txt"
overlay_paths "$dir" >"$out/overlay-paths.txt"
while IFS=$'\t' read -r name src; do
    if [ -e "$src/packages.txt" ]; then names "$src/packages.txt" >>"$out/packages/install.txt"; fi
    if [ -e "$src/exclude.txt" ]; then names "$src/exclude.txt" >>"$out/packages/exclude.txt"; fi
    for hook in pre-install.sh post-install.sh; do
        if [ -e "$src/$hook" ]; then mkdir -p "$out/packages/$name" && cp -a "$src/$hook" "$out/packages/$name/"; fi
    done
    if [ -d "$src/overlay/etc/yum.repos.d" ]; then
        mkdir -p "$out/packages/$name/overlay/etc"
        cp -a "$src/overlay/etc/yum.repos.d" "$out/packages/$name/overlay/etc/"
    fi
    if [ -e "$src/sign.sh" ]; then mkdir -p "$out/sign/$name" && cp -a "$src/sign.sh" "$out/sign/$name/"; fi
    cp -a "$src" "$out/all/$name"
    if [ -d "$src/overlay" ]; then cp -a "$src/overlay/." "$out/overlay/"; fi
    # A build gets what it may use and nothing that would rerun it for no
    # reason: build.sh and the files next to it.
    if [ -e "$src/build.sh" ]; then
        mkdir -p "$out/builds/$name"
        for file in "$src"/*; do
            if [[ $known != *" ${file##*/} "* || ${file##*/} == build.sh ]]; then
                cp -a "$file" "$out/builds/$name/"
            fi
        done
    fi
done < <(features "$dir")
