#!/usr/bin/env bash
#
# The ssh feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# SSH: password auth for non-root accounts, with a pre-auth legal notice.
# Asked of sshd rather than grepped, because drop-ins are first-match-wins and
# what matters is the value sshd ends up with. sshd needs a host key before it
# prints its config, hence the throwaway one. Keywords are case-insensitive
# and sshd -T prints them lowercase (OpenSSH 10.2, Fedora 44) or as
# documented, PermitRootLogin (10.5, Fedora 45), so only the keyword is
# lowercased; values are compared as they are.
ssh-keygen -q -t ed25519 -N '' -f /tmp/sshd-check
sshd -t -h /tmp/sshd-check
sshd_effective=$(sshd -T -h /tmp/sshd-check | awk '{ $1 = tolower($1) } 1')
grep -qx 'permitrootlogin prohibit-password' <<<"$sshd_effective"
grep -qx 'passwordauthentication yes' <<<"$sshd_effective"
grep -qx 'permitemptypasswords no' <<<"$sshd_effective"
grep -qx 'banner /usr/share/fedora-bootc/ssh-banner' <<<"$sshd_effective"
test -s /usr/share/fedora-bootc/ssh-banner
rm -f /tmp/sshd-check /tmp/sshd-check.pub
