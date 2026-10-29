# Install fedora-bootc

You need UEFI, a network connection, and Secure Boot off or the firmware in
Setup Mode. The live ISO also needs 16 GB of RAM. To install from a fork,
first follow [Create your own fork](fork.md). You can also
[pull the image through a cache](pull-through-cache.md). After the first boot,
[set up Secure Boot and TPM2 auto-unlock](secureboot-tpm2.md).

> [!IMPORTANT]
> The boot keymap is Swiss (`ch`). Pick a LUKS passphrase you can type on it.

Install `nvidia-uki` for an NVIDIA GTX 16 / RTX 20 series GPU or newer, and
`latest-uki` otherwise. Replace the example disk `/dev/nvme0n1` with yours.

## Install from the live ISO

1. Write `fedora-bootc-live.iso` from a
   [release](https://github.com/lucarickli/fedora-bootc/releases) to a USB
   drive, which erases it. `USB_DEVICE` is the drive, for example `/dev/sdb`:

   ```sh
   sudo cp fedora-bootc-live.iso USB_DEVICE && sync
   ```

2. Boot from the USB drive. The
   [bootc-installer](https://github.com/tuna-os/bootc-installer) wizard picks
   the image itself. To choose it yourself, press `e` in the boot menu, append
   `fedora-bootc.variant=nvidia` or `fedora-bootc.variant=default` to the
   `linux` line, and press Ctrl+X.

3. For Wi-Fi, press Ctrl+Alt+F2, run `nmtui`, and return to the wizard with
   Ctrl+Alt+F1.

4. In the encryption step, set a passphrase and turn
   **Use hardware-backed encryption** off. On this image, that TPM2 option
   only leaves a copy of the passphrase on the encrypted disk. If it was on,
   change the passphrase after the first boot with
   `sudo cryptsetup luksChangeKey /dev/nvme0n1p2`.

5. Create your user in the wizard. Nothing else creates one.

If the install fails, run these commands on the Ctrl+Alt+F2 console, as
`liveuser`:

```sh
cat ~/.cache/bootc-installer/fisherman-output.log   # the installer's log
dmesg | grep 'writable overlay'                     # the live system's writable space
```

## Install manually from a live USB drive

On a live system with an overlay root, such as a Fedora live ISO, podman fails
with `'overlay' is not supported over overlayfs`. Give podman a mount program:

```sh
sudo tee /etc/containers/storage.conf > /dev/null << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
```

### Disk layout

The kernel command line sealed into the unified kernel image (UKI) has no
`root=`, so the initramfs finds the root partition by its GPT type. Every
install needs these partitions:

| Partition                           | GPT type                         | Content                                                                    |
| ----------------------------------- | -------------------------------- | -------------------------------------------------------------------------- |
| EFI system partition, 1 GiB or more | `esp` (`c12a7328-...`)           | vfat with systemd-boot and the UKIs, mounted at `/boot` during the install |
| Root, rest of the disk              | `root (x86-64)` (`4f68bce3-...`) | btrfs **at the top level, no subvolumes**, optionally inside LUKS2         |

### Create a user

The image has no users. Add `--root-ssh-authorized-keys KEY_FILE` to the
`bootc install` command, where `KEY_FILE` is your SSH public key's path inside
the container. For Option A, mount the key with
`-v ~/.ssh/id_ed25519.pub:/key.pub:ro` and use `/key.pub`. For Option B,
prefix the key's path with `/run/host`.

After the first boot, create your user over SSH:

```sh
ssh root@MACHINE
useradd -m -G wheel USERNAME
passwd USERNAME
```

To add a user offline instead, follow
[`scripts/vm-demo-user.sh`](../scripts/vm-demo-user.sh).

### Option A: Install to a whole disk without encryption

This erases the whole disk and creates the layout:

```sh
sudo podman run --rm --privileged --pid=host \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
    --security-opt label=type:unconfined_t \
    ghcr.io/lucarickli/fedora-bootc:latest-uki \
    bootc install to-disk --wipe \
      --bootloader=systemd --composefs-backend \
      /dev/nvme0n1
```

### Option B: Install with LUKS encryption

> [!WARNING]
> Step 1 erases the whole disk. Until step 4, the LUKS passphrase is empty.

1. From a checkout of this repository, partition the disk:

   ```sh
   sudo systemd-repart --empty=force --dry-run=no --discard=no \
       --definitions=docs/repart.d /dev/nvme0n1
   ```

2. Open the LUKS volume and mount the filesystems. At the passphrase prompt,
   press Enter:

   ```sh
   sudo cryptsetup open /dev/nvme0n1p2 root
   sudo mount /dev/mapper/root /mnt
   sudo mkdir /mnt/boot
   sudo mount /dev/nvme0n1p1 /mnt/boot
   ```

3. Pull the image and install it:

   ```sh
   sudo podman pull ghcr.io/lucarickli/fedora-bootc:latest-uki
   sudo podman run --rm --privileged --pid=host --ipc=host \
       --security-opt label=type:unconfined_t \
       -v /var/lib/containers:/var/lib/containers -v /dev:/dev \
       -v /:/run/host \
       ghcr.io/lucarickli/fedora-bootc:latest-uki \
       bootc install to-filesystem \
         --source-imgref=containers-storage:ghcr.io/lucarickli/fedora-bootc:latest-uki \
         --bootloader=systemd --composefs-backend --skip-finalize \
         /run/host/mnt
   ```

   If the pull runs out of space and the machine has enough RAM, first run
   `sudo mount -t tmpfs -o size=10G tmpfs /var/lib/containers/storage`.

4. Add your passphrase and remove the empty one. Press Enter when asked for
   the existing passphrase or the one to remove:

   ```sh
   sudo cryptsetup luksAddKey /dev/nvme0n1p2
   sudo cryptsetup luksRemoveKey /dev/nvme0n1p2
   ```

5. Unmount and reboot:

   ```sh
   sync
   sudo umount -R /mnt
   sudo cryptsetup close root
   sudo reboot
   ```

Option B follows
[travier/fedora-atomic-desktops-sealed](https://github.com/travier/fedora-atomic-desktops-sealed)
and is untested on hardware.

## First boot

The machine boots to the Noctalia greeter. Log in with the user you created.
If the install or boot fails with `wrong composefs= parameter`, the repository
owner must rebuild and push the image. If the boot stops in a dracut emergency
shell, see [Recover a system](rescue.md).
