# Secure Boot + TPM2 auto-unlock

Do this once the installed machine boots: enroll the keys first and bind the
TPM last, because enrolling keys changes PCR 7.

## Enroll the keys

Every image carries your keys ready to enroll: PK, KEK and db as signed EFI
variables (`PK.auth`, `KEK.auth`, `db.auth`), signed by the build with the PK
and KEK keys ([keys/README.md](../keys/README.md)). `bootc install` puts them
on the ESP in `loader/keys/<set>/`, and while the firmware is in Setup Mode
systemd-boot offers each set as an entry of its boot menu, "Enroll Secure
Boot keys: <set>", which writes them into the firmware. No private key goes
near the machine. A machine installed before the image had them gets them
on its first boot of such an image (`secureboot-keys.service`;
`journalctl -b -u secureboot-keys` says when it wrote them).

| Set                          | Trusts                                                                                                                                                                                                           | For                                                                                                                                |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `fedora-bootc-and-microsoft` | your db, and what Microsoft signs: the Windows boot manager, other bootloaders (shim, so other distributions' installers too), the firmware of add-in cards (option ROMs); Microsoft's KEK can update db and dbx | most machines: dual boot, an NVIDIA card (its own firmware gives the picture before the OS), any graphics, network or storage card |
| `fedora-bootc-only`          | your db alone                                                                                                                                                                                                    | a machine that must boot nothing but this OS: no Windows, no other USB stick                                                       |

`fedora-bootc-only` also stops the firmware of add-in cards: with a discrete
graphics card that can mean no picture before the OS starts, and a network or
storage card can vanish from the firmware. So it is not offered on a machine
whose boot ran such firmware: `secureboot-keys.service` reads that from the
TPM's event log, as sbctl did, and takes the set off the ESP, once the OS has
started (right after an install both sets are there). Without a TPM nothing
checks it; take it only where display and boot disk work without add-in cards
(integrated graphics, NVMe on the board), and know how to clear the keys in
your firmware setup again. When unsure, `fedora-bootc-and-microsoft`.

1. Try it in a VM: `just qcow2 && just vm-enroll` (`just vm-enroll
   fedora-bootc-only` for the other set).
2. Have the LUKS passphrase at hand: with new keys the TPM no longer unlocks
   the disk until it is bound again (below). Dual boot: suspend BitLocker in
   Windows first, or have its recovery key ready, for the same reason.
3. From a host shell (bootctl refuses this inside a toolbox), pick the set
   for the next boot and reboot into the firmware setup:

   ```sh
   sudo bootctl set-oneshot secure-boot-keys-fedora-bootc-and-microsoft   # or secure-boot-keys-fedora-bootc-only
   sudo systemctl reboot --firmware-setup
   ```

   Firmware that cannot be asked for its setup this way (`bootctl status`:
   "Boot into FW: not supported"): plain `sudo systemctl reboot`, and press
   its setup key at power-on.
4. In the firmware setup, put it in Setup Mode. Where it offers to delete the
   PK alone (AMI: Key Management, Platform Key, Delete; Lenovo: "Reset to
   Setup Mode"), take that: it keeps dbx, the list of revoked bootloaders.
   "Clear all keys", "Delete all Secure Boot variables" and AMI's "Reset To
   Setup Mode" empty dbx as well (below). On AMI firmware turn "Factory Key
   Provision" off first, or it puts its own keys back at the next start.
   Secure Boot's own switch can be turned on now or after enrolling (6).
   Save and exit.
5. systemd-boot shows `Warning: Enrolling custom Secure Boot keys might
   soft-brick your machine!` and counts down 15 s (any key aborts, nothing is
   written), then writes db, KEK and PK and reboots.

   - The OS starts instead: `bootctl status`. "disabled (setup)" means Setup
     Mode, with nothing enrolled: the one-shot is used up by the first start
     of systemd-boot, so it ran before the firmware was in Setup Mode, or the
     enrollment failed (systemd-boot shows `Failed to write ...`; see it by
     holding Space at power-on and picking the entry). Setup Mode already, so
     skip 4: the `bootctl` line of 3, then `sudo systemctl reboot`. User mode
     with the firmware's own keys (`mokutil --pk`): it put them back; turn
     that off (4) and start again at 3.
   - The firmware refuses to start anything (a Secure Boot violation, or
     Windows starts): it is not in Setup Mode, and Secure Boot is on. Press
     its setup key at power-on and do 4 again, or turn Secure Boot off; the
     one-shot is still set.
   - By hand, without the one-shot: hold Space at power-on (Fast Boot may skip
     the keyboard) and pick "Enroll Secure Boot keys: <set>", the last
     entries, there only in Setup Mode. A machine installed with its keys
     cleared (Setup Mode enforces nothing, so the ISO starts) is in Setup
     Mode already and skips 4.

6. Check:

   ```sh
   mokutil --sb-state          # SecureBoot enabled
   bootctl status              # Secure Boot: enabled (user)
   mokutil --pk | grep -i 'sha1 fingerprint'
   ```

   The fingerprint is your PK's, the one `openssl x509 -noout -fingerprint
   -sha1 -in keys/PK/PK.pem` shows from the repository. Still disabled: turn
   Secure Boot on in the firmware setup, where it is a switch of its own.

From then on the firmware starts only what the set's db trusts: this OS's
UKIs, signed with your db key, which is why CI refuses to push unsigned
builds, and with `fedora-bootc-and-microsoft` what Microsoft signed.
systemd-boot writes no dbx: where 4 emptied it, `fedora-bootc-and-microsoft`
trusts again what Microsoft has revoked. Restore it before binding the TPM,
with `fwupdmgr refresh && fwupdmgr update` (the "UEFI dbx" device; `fwupdmgr
get-devices` shows its version) or Windows Update, which Microsoft's KEK in
that set lets in. `fedora-bootc-only` takes no Microsoft dbx update and needs
none, as it trusts nothing Microsoft signed. Any dbx update changes PCR 7
too: apply it before binding the TPM, or bind it again after.

## New keys

An image built with a new db key does not start on a machine that enforces
the old one, so move the machines over one at a time, by hand:

1. `sudo bootc upgrade` stages the new image; the running one stays as the
   rollback.
2. `sudo systemctl reboot --firmware-setup`, and put the firmware in Setup
   Mode (4 above). The new image starts, since Setup Mode enforces nothing;
   type the LUKS passphrase. This boot puts its sets on the ESP.
3. Replace systemd-boot, which bootc never updates, so it is still signed
   with the old key. The ESP is not mounted otherwise:

   ```sh
   esp=$(bootctl status 2>/dev/null | awk '/Partition:/ { print $2; exit }')   # /dev/disk/by-partuuid/...
   sudo mount -o umask=0077 "$esp" /mnt
   sudo bootctl install --esp-path=/mnt --no-variables
   sudo umount /mnt
   ```

4. `sudo bootctl set-oneshot secure-boot-keys-<set> && sudo systemctl
   reboot`: systemd-boot enrolls the new keys (5 above).
5. Bind the TPM again (below).

The rollback, signed with the old key, no longer starts with Secure Boot on;
the next upgrade replaces it. A new PK or KEK alone, with the db key kept,
needs none of this: the new image starts as before, puts its sets on the ESP,
and the steps under "Enroll the keys" enroll them.

## NVIDIA

The nvidia images' kernel modules are signed with the db key
([`extras/nvidia/`](../extras/nvidia/features/nvidia/sign.sh)), and Fedora's
kernel checks module signatures against the firmware's db as well (its
platform keyring), so with either set enrolled they load with Secure Boot on;
no shim or MOK is needed. Not yet tried on hardware; once enrolled:

```sh
lsmod | grep '^nvidia'                        # loaded
modinfo -F signer nvidia                      # the db certificate's name
journalctl -k -b | grep -i 'Loaded X.509'     # your db certificate among those the kernel took from the firmware
```

If they are refused, `nvidia-fallback.service` silently loads nouveau, and
`journalctl -k -b | grep -i nvidia` says why. The card's own firmware, which
gives the picture before the OS starts, is signed by Microsoft: that is what
makes `fedora-bootc-and-microsoft` the set for these machines.

## TPM2 auto-unlock

Bind the LUKS volume to PCR 7 (Secure Boot state), which image updates do not
change; the passphrase stays as the fallback.

```sh
lsblk -o NAME,FSTYPE,MOUNTPOINT                            # find the crypto_LUKS partition
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2
sudo systemd-cryptenroll /dev/nvme0n1p2                    # list: SLOT 0 password, SLOT 1 tpm2
```

The UKI already asks the TPM first (`kargs.d/20-luks-tpm2.toml`). If the TPM
state changes (firmware update, new keys, a dbx update), type the passphrase
at boot, then replace the TPM2 slot:

```sh
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2
```
