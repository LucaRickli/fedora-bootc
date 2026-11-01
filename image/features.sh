#!/usr/bin/env bash
#
# The features of one image (images/NAME/), checked, and sorted into what
# each build step reads. Run by the `features` stage of image/os.Containerfile
# and by `just check`.
#
#   features.sh IMAGE             check the image's features
#   features.sh --list IMAGE      check them, then print their names
#   features.sh --out OUT IMAGE   check them, then sort them into OUT
#
# IMAGE is a folder of links (images/README.md), each named like what it
# leads to: a feature, a folder of features/, or another image, whose
# features it brings in. A feature reached twice counts once. A feature's
# files, each optional:
#
#   groups.txt       Fedora comps groups, one ID per line, installed in a step
#                    of their own before the packages (groups.sh)
#   packages.txt     RPMs to install, one per line; # starts a comment
#   exclude.txt      RPMs kept out of the group step and the package
#                    transaction (such as weak dependencies that would only
#                    duplicate another), the same way
#   pre-install.sh   before the dnf transaction: what packages.txt cannot say
#   post-install.sh  right after it, in its layer
#   build.sh         builds what Fedora does not package, from the files next
#                    to it, in a throwaway stage (builds.sh)
#   sign.sh          a step of its own, with the Secure Boot db key and no
#                    network (sign.sh)
#   overlay/         files copied verbatim onto /
#   setup.sh         once everything is in place: setup, then the checks that
#                    prove it (finalize.sh)
#
# OUT gets each build step's part, so that editing a feature's files or setup
# does not rerun a package step:
#
#   OUT/groups/            groups.txt, sorted, and exclude.txt, one name per
#                          line
#   OUT/packages/          install.txt and exclude.txt, one name per line, and
#                          per feature its pre-/post-install.sh and .repo files
#   OUT/sign/<feature>/    its sign.sh
#   OUT/all/<feature>/     the whole feature, for finalize.sh
#   OUT/overlay/           every overlay/, merged
#   OUT/builds/<feature>/  its build.sh and the files next to it
#   OUT/overlay-paths.txt  every overlay path, for finalize.sh to check the
#                          builds against
#   OUT/excluded.txt       every exclude.txt name, for finalize.sh to check
#                          that none is installed
set -euo pipefail
shopt -s nullglob

usage='usage: features.sh [--out OUT | --list] IMAGE'
out='' list_only=''
case ${1:-} in
    --out) out=$(realpath -m "${2:?$usage}"); shift 2 ;;
    --list) list_only=1; shift ;;
esac
image=$(realpath "${1:?$usage}")
[ -d "$image" ] || { echo "${1}: not an image folder" >&2; exit 1; }
images_dir=${image%/*}
features_dir=$(realpath -m "$images_dir/../features")

errors=()
err() { errors+=("$*"); }

# The image's features, its links to other images followed: feature[NAME]
# is the folder of features/ that NAME leads to.
declare -A feature=() state=()
resolve() {
    local img=$1 entry name target n=0
    case ${state[$img]:-} in
        closed) return ;;
        open) err "${img##*/}: an image that includes itself"; return ;;
    esac
    state[$img]=open
    for entry in "$img"/*; do
        n=$((n + 1))
        name=${entry##*/}
        if [ ! -L "$entry" ]; then
            err "${img##*/}/$name: not a link (an image holds links to features and images)"
            continue
        fi
        # The build copies images/ and features/ elsewhere, where only a
        # relative link still leads to the same folder.
        case $(readlink -- "$entry") in
            /*) err "${img##*/}/$name: an absolute link (make it ../../features/$name or ../$name)"; continue ;;
        esac
        target=$(realpath -m "$entry")
        if [ "${target##*/}" != "$name" ]; then
            err "${img##*/}/$name: leads to ${target##*/}, not to a folder named like the link"
        elif [ "${target%/*}" = "$features_dir" ] && [ -d "$target" ]; then
            feature[$name]=$target
        elif [ "${target%/*}" = "$images_dir" ] && [ -d "$target" ]; then
            resolve "$target"
        else
            err "${img##*/}/$name: leads to $target, not to a folder of features/ or images/"
        fi
    done
    [ "$n" -gt 0 ] || err "${img##*/}: no features"
    state[$img]=closed
}
resolve "$image"

# The image's features, sorted by name, each as NAME<tab>PATH: the order of
# the hooks and of the package lists.
features() {
    local name
    for name in "${!feature[@]}"; do printf '%s\t%s\n' "$name" "${feature[$name]}"; done | LC_ALL=C sort
}

# The names in groups.txt, packages.txt or exclude.txt: comments and blank
# lines aside, each on a line of its own even when the file lacks a final
# newline (the lists of all features are appended into one).
names() { { cat "$1"; echo; } | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'; }

# Every overlay path of every feature, as it lands on /. Symlinks inside an
# overlay are files to ship, never followed.
overlay_paths() {
    local name src
    while IFS=$'\t' read -r name src; do
        if [ -d "$src/overlay" ]; then
            (cd "$src/overlay" && find . \( -type f -o -type l \) -printf '%P\n')
        fi
    done < <(features) | LC_ALL=C sort
}

known=' groups.txt packages.txt exclude.txt pre-install.sh post-install.sh build.sh sign.sh overlay setup.sh '
while IFS=$'\t' read -r name src; do
    case $name in
        *[!a-z0-9-]*) err "feature names are lower-case letters, digits and -: $name" ;;
    esac
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
    for list in groups.txt packages.txt exclude.txt; do
        if [ -e "$src/$list" ] && names "$src/$list" | grep -q '[[:space:]]'; then
            err "$name/$list: one name per line"
        fi
        # A name, never an option: dnf and rpm would take --nogpgcheck as one.
        if [ -e "$src/$list" ] && names "$src/$list" | grep -q '^-'; then
            err "$name/$list: a name starts with -"
        fi
    done
done < <(features)

# No two features of the image ship the same file: the overlays are copied
# onto / one after the other, and the last would silently win.
while read -r path; do
    err "shipped by more than one feature: $path"
done < <(overlay_paths | uniq -d)

if [ ${#errors[@]} -gt 0 ]; then
    printf '%s\n' "${errors[@]}" >&2
    exit 1
fi
if [ -n "$list_only" ]; then
    features | cut -f1
    exit 0
fi
[ -n "$out" ] || exit 0

mkdir -p "$out/groups" "$out/packages" "$out/sign" "$out/all" "$out/overlay" "$out/builds"
: >"$out/groups/groups.txt"
: >"$out/groups/exclude.txt"
: >"$out/packages/install.txt"
: >"$out/packages/exclude.txt"
: >"$out/excluded.txt"
overlay_paths >"$out/overlay-paths.txt"
while IFS=$'\t' read -r name src; do
    if [ -e "$src/groups.txt" ]; then names "$src/groups.txt" >>"$out/groups/groups.txt"; fi
    if [ -e "$src/packages.txt" ]; then names "$src/packages.txt" >>"$out/packages/install.txt"; fi
    if [ -e "$src/exclude.txt" ]; then
        names "$src/exclude.txt" >>"$out/groups/exclude.txt"
        names "$src/exclude.txt" >>"$out/packages/exclude.txt"
        names "$src/exclude.txt" >>"$out/excluded.txt"
    fi
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
done < <(features)
# Sorted, not in feature order: the order is an input of rpm's install
# order, and with it of the user and group IDs the group step's packages get.
LC_ALL=C sort -u -o "$out/groups/groups.txt" "$out/groups/groups.txt"
