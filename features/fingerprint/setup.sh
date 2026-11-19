#!/usr/bin/env bash
#
# The fingerprint feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: pam_fprintd for sudo and
# polkit, the password alone for the login screen and the lock screen's
# password field, then its checks (the marked section at the end).
#
set -euxo pipefail

# The PAM file a service reads: one in /etc/pam.d shadows one in
# /usr/lib/pam.d.
pam_file() {
    local dir
    for dir in /etc/pam.d /usr/lib/pam.d; do
        if [ -e "$dir/$1" ]; then
            echo "$dir/$1"
            return 0
        fi
    done
    echo "no PAM service $1" >&2
    return 1
}

# The modules a service's auth stack runs, one per line, its include and
# substack lines followed: what tells whether the service can take a
# fingerprint (pam_fprintd.so) and still takes the password (pam_unix.so). A
# control can be a [value=action ...] list with blanks in it, and a type can
# start with -, which only makes a missing module no error. The returns are
# spelled out: a command substitution, where the checks call this, does not
# stop on errors.
auth_modules() {
    local file control module depth=${2:-0}
    if [ "$depth" -gt 8 ]; then
        echo "PAM includes nested too deep at $1" >&2
        return 1
    fi
    file=$(pam_file "$1") || return 1
    while read -r control module; do
        case $control in
            include | substack) auth_modules "$module" $((depth + 1)) || return 1 ;;
            *) echo "${module##*/}" ;;
        esac
    done < <(awk '
        { sub(/#.*/, "") }
        $1 != "auth" && $1 != "-auth" { next }
        {
            i = 2
            if ($i ~ /^\[/) { while ($i !~ /\]$/ && i < NF) i++ }
            print (i == 2 ? $2 : "[...]"), $(i + 1)
        }' "$file")
}

# --- pam_fprintd for sudo and polkit ------------------------------------------
# authselect's with-fingerprint feature puts pam_fprintd in system-auth, in
# front of pam_unix, and keeps it out of password-auth. sudo, su and polkit
# (pkexec, run0, the Noctalia shell's polkit prompts) include system-auth; the
# remote logins, sshd, xrdp and cockpit, include password-auth. pam_fprintd
# steps aside on its own for a remote session as well (PAM_RHOST set, or a
# logind session marked remote: sudo over SSH or RDP), and for an account
# without an enrolled finger or a machine without a reader, which get the
# password prompt at once. Anaconda turns the feature on when it installs
# Fedora with fprintd; an image never meets Anaconda, so it is turned on here.
authselect enable-feature with-fingerprint

# --- The login screen and the lock screen: the password -----------------------
# Two services that include system-auth stay without the reader:
# - greetd, the login screen. noctalia-greeter takes the password before it
#   starts PAM, and answers PAM's first password prompt with it
#   (src/greeter/greeter_surface.cpp, tryAuthenticate), so pam_fprintd in
#   front would only hold every login for its 30-second scan. A login by
#   fingerprint would also leave the login keyring locked: pam_gnome_keyring
#   unlocks it with the password.
# - login. The Noctalia shell's lock screen scans the reader itself, through
#   fprintd's D-Bus API, next to its password field. A typed password stops
#   that scan and goes to this service (src/shell/lockscreen/lock_screen.cpp,
#   Noctalia 5), where pam_fprintd would scan for another 30 seconds before
#   it took the password. Logins on the console use the service too.
# So their auth stacks include password-auth instead, which is system-auth's
# auth stack without pam_fprintd, as GDM's password login does.
for service in greetd login; do
    file=$(pam_file "$service")
    sed -i -E 's/^(-?auth[[:space:]]+(include|substack)[[:space:]]+)system-auth([[:space:]]*)$/\1password-auth\3/' "$file"
done

# --- Checks -----------------------------------------------------------------
# fprintd starts on demand, through D-Bus (no preset), and keeps the prints in
# /var/lib/fprint, which systemd creates when it starts it (StateDirectory=):
# an update never brings the image's /var.
test -x /usr/libexec/fprintd
test -f /usr/lib64/security/pam_fprintd.so
grep -qx 'SystemdService=fprintd.service' /usr/share/dbus-1/system-services/net.reactivated.Fprint.service
grep -qx 'StateDirectory=fprint' /usr/lib/systemd/system/fprintd.service
# The feature is on, and authselect's files are as it wrote them: one edited
# behind its back makes the next authselect command refuse to run.
[[ " $(authselect current --raw) " == *" with-fingerprint "* ]]
authselect check
# Who takes a fingerprint, the includes followed: sudo and polkit do; the
# login screen, the lock screen's password (login) and password-auth, which
# the remote logins include, do not. All of them still take the password.
for service in sudo polkit-1; do
    modules=$(auth_modules "$service")
    grep -qx pam_fprintd.so <<<"$modules"
    grep -qx pam_unix.so <<<"$modules"
done
for service in greetd login password-auth; do
    modules=$(auth_modules "$service")
    if grep -qx pam_fprintd.so <<<"$modules"; then
        echo "the PAM service $service takes a fingerprint" >&2
        exit 1
    fi
    grep -qx pam_unix.so <<<"$modules"
done
