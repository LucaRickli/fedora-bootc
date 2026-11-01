#!/usr/bin/env bash
#
# Rebuild the initramfs as the last change to the rootfs, in the `split`
# stage of image/seal.Containerfile, from the image's dracut configuration,
# which features add to (features/README.md), then check that everything it
# declares made it in.
# `bootc container split-kernel-and-rootfs` then lifts kernel + initramfs out
# of the rootfs and into the UKI.
#
set -euxo pipefail

kver=$(cd /usr/lib/modules && echo *)
img=/usr/lib/modules/${kver}/initramfs.img

# Everything else comes from dracut.conf.d (sourced by dracut).
dracut --no-hostonly --reproducible --kver "$kver" -f "$img"
chmod 0600 "$img"

# --- Checks -----------------------------------------------------------------
# What the dracut configuration declares must be in the image, whichever file
# declares it (a feature's, the base image's, a package's). dracut stops on a
# declared dracut module it cannot install, but for a declared kernel module
# or file it cannot find it only logs "FAILED", and it drops a declared
# dracut module that another file omits without a word; it writes the image
# either way. fedora_bootc_check_items, which dracut ignores, names files a
# dracut module installs by itself: checked, never installed. (The listing
# goes to a file: with pipefail, a reader that exits early, like `grep -q`,
# makes lsinitrd fail with SIGPIPE.)
LC_ALL=C lsinitrd "$img" > /tmp/initramfs.lst

# What the image has: "m <dracut module>", "f <path>", "d <kernel module>"
# (a .ko* in the image, or built into the kernel), - in module names as _.
{
    awk '
        /^dracut modules:$/ { s = "m"; next }
        /^=+$/ { s = s == "m" ? "f" : ""; next }
        s == "m" && NF { print "m " $0 }
        s == "f" && NF {
            sub(/^[^ ]+ +[0-9]+ +[^ ]+ +[^ ]+ +([0-9]+, +)?[0-9]+ +[A-Z][a-z][a-z] +[0-9]+ +[0-9:]+ /, "")
            sub(/ -> .*/, "")
            print "f " $0
            if (sub(/\.ko(\.[a-z0-9]+)?$/, "")) { sub(/.*\//, ""); gsub(/-/, "_"); print "d " $0 }
        }' /tmp/initramfs.lst
    sed -e 's|.*/||' -e 's|\.ko$||' -e 'y/-/_/' -e 's|^|d |' "/usr/lib/modules/${kver}/modules.builtin"
} | LC_ALL=C sort -u > /tmp/initramfs.have

# What the configuration declares, read the way dracut reads it:
# /etc/dracut.conf, then the *.conf of /etc/dracut.conf.d and
# /usr/lib/dracut/dracut.conf.d by file name in version order (sort -V), one
# in /etc replacing a /usr/lib one of the same name. Files as dracut-install
# puts them: a name without / looked up in PATH, symlinked directories
# resolved (/usr/sbin is a symlink to bin). The configuration is sourced with
# its output on stderr: stdout is the list.
# shellcheck disable=SC2154  # dracut's keys, set by the sourced configuration
(
    set +eux
    # shellcheck disable=SC1091
    [ ! -f /etc/dracut.conf ] || . /etc/dracut.conf >&2
    for name in $(for conf in /etc/dracut.conf.d/*.conf /usr/lib/dracut/dracut.conf.d/*.conf; do
                      [ ! -e "$conf" ] || echo "${conf##*/}"
                  done | LC_ALL=C sort -Vu); do
        # shellcheck disable=SC1090
        if [ -e "/etc/dracut.conf.d/$name" ]; then . "/etc/dracut.conf.d/$name" >&2; else . "/usr/lib/dracut/dracut.conf.d/$name" >&2; fi
    done
    for m in $add_dracutmodules $force_add_dracutmodules; do echo "m $m"; done
    for d in $add_drivers $force_drivers $filesystems; do echo "d ${d//-/_}"; done
    for f in $install_items $fedora_bootc_check_items; do
        [[ $f == /* ]] || f=$(type -P "$f" || echo "$f")
        d=$(cd -P "${f%/*}/" 2> /dev/null && pwd) && f=${d%/}/${f##*/}
        echo "f ${f#/}"
    done
) | LC_ALL=C sort -u > /tmp/initramfs.want

missing=$(LC_ALL=C comm -23 /tmp/initramfs.want /tmp/initramfs.have)
if [ -n "$missing" ]; then
    printf 'initramfs: declared in dracut.conf.d but missing:\n%s\n' "$missing" >&2
    exit 1
fi
rm -f /tmp/initramfs.lst /tmp/initramfs.have /tmp/initramfs.want
