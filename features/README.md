# Features

Each folder in `features/` is one feature, which the
[images](../images/README.md) that link it have. A feature has these optional
files, in build order:

| File              | What it is                                                                                                                                                                                    |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build.sh`        | Builds what Fedora doesn't package, from pinned upstream sources and the files next to it, in a throwaway stage ([`image/builds.sh`](../image/builds.sh))                                     |
| `groups.txt`      | Fedora comps groups, one ID per line, installed in a step of their own before every feature's packages ([`image/groups.sh`](../image/groups.sh))                                              |
| `pre-install.sh`  | What `packages.txt` can't express, such as a repository from a release package                                                                                                                |
| `packages.txt`    | RPMs to install, one per line, with `#` for comments; all features share one dnf transaction ([`image/packages.sh`](../image/packages.sh))                                                    |
| `exclude.txt`     | RPMs or globs to keep out of the comps groups and the transaction, such as weak dependencies that duplicate another; the build fails if one is installed anyway                               |
| `post-install.sh` | What must happen in the transaction's layer, such as removing keys a package generated                                                                                                        |
| `sign.sh`         | What needs the Secure Boot signature database (db) key, such as signing systemd-boot, in a step of its own with no network ([`image/sign.sh`](../image/sign.sh))                              |
| `overlay/`        | Files copied verbatim onto the image; no two features can ship the same path                                                                                                                  |
| `setup.sh`        | Build-time setup, then the checks that prove it and what it needs from other features, after a `# --- Checks` marker; runs in folder name order ([`image/finalize.sh`](../image/finalize.sh)) |

RPMs a `build.sh` leaves in `$OUT/rpm` join the package transaction; files in
`$OUT/root` land on the image.

A feature that enables or disables services ships
`overlay/usr/lib/systemd/system-preset/80-fedora-bootc-FEATURE.preset`, or the
same file in `user-preset/`, where `FEATURE` is the folder name.

A feature that needs something in the initramfs ships
`overlay/usr/lib/dracut/dracut.conf.d/80-fedora-bootc-FEATURE.conf`, each
entry as `KEY+=" NAME "` with the spaces: dracut modules in
`add_dracutmodules`, kernel modules in `force_drivers` or `add_drivers`, and
files in `install_items`. A file that a dracut module installs itself goes in
`fedora_bootc_check_items`, which dracut ignores.
[`image/initramfs.sh`](../image/initramfs.sh) fails the seal if the initramfs
lacks anything that the dracut configuration declares.

A `sign.sh` finds the db key and its certificate at
`/run/secrets/secureboot_key` and `/run/secrets/secureboot_cert`.

All of an image's packages install in one transaction, and a system account
that a package creates takes the next free ID. A feature that only some
images have creates such accounts in `pre-install.sh`, with fixed IDs far
below the shared accounts' IDs, and checks them in `setup.sh`, as `nvidia`
does for `akmods` (800). Otherwise the accounts created after it get other
IDs than in the other images, and a machine, which keeps its own
`/etc/passwd` and `/etc/group` when it updates or switches images, would give
the image's files to the wrong accounts.

A new feature needs its folder and a link in an image, such as
`images/latest/`, which also gives it to every image that links that image,
such as `nvidia`. A feature for only some machines gets a link in their image
alone ([Images](../images/README.md)). A comps group, a package, or a build
needs no change outside the feature's folder.
[`image/features.sh`](../image/features.sh) checks each image's features in
every build and in `just check`. To remove a feature, delete its folder and
its links. A feature that relies on it then fails its checks.

Some features are also used outside `features/`:

- `boot`: the `qcow2` recipe in the [`Justfile`](../Justfile), the
  [installer](../installer/), and [Install fedora-bootc](../docs/install.md)
  install with its bootloader and root filesystem, and
  [`image/uki-trust.sh`](../image/uki-trust.sh) checks its systemd-boot, so
  change them together.
- `locale`: [`installer/configure-installer.sh`](../installer/configure-installer.sh)
  sets the same keyboard layout for the LUKS passphrase, so change both
  together.
- `updates`: [`installer/live.Containerfile`](../installer/live.Containerfile)
  copies its signature policy.

The repository has these features:

| Feature          | What it provides                                                                                                                                    |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base`           | The core system and hardware support, command-line basics, such as git and the GitHub CLI, and account defaults, such as fish and `/var/home`       |
| `boot`           | bootc install configuration and kernel arguments, LUKS, quiet boot, a hidden boot menu, and Secure Boot enrollment sets on the EFI system partition |
| `cockpit`        | Cockpit web console, off by default, on loopback only                                                                                               |
| `containers`     | podman and toolbox, Docker next to them, and the podman API socket                                                                                  |
| `desktop`        | The graphical base without GNOME, the Noctalia shell, portals, keyring, SSH agent, file manager, audio, and dark mode                               |
| `fail2ban`       | Bans hosts after repeated login failures on SSH and XRDP                                                                                            |
| `flatpak`        | Flatpak with the Flathub and Devolutions remotes                                                                                                    |
| `llm`            | shimmy, a local LLM server, off by default; see [Local LLM](../docs/os.md#local-llm)                                                                |
| `locale`         | Time zone and keyboard layout for the console, X11, and Wayland                                                                                     |
| `login`          | greetd and noctalia-greeter, which `build.sh` builds from source                                                                                    |
| `nvidia`         | The NVIDIA driver, with kernel modules built and signed at build time; only in the `nvidia` image, see [NVIDIA driver](../docs/os.md#nvidia-driver) |
| `sessions`       | niri, labwc, sway, river, and wayfire, set up for Noctalia                                                                                          |
| `smb`            | SMB client for shares on other machines, such as Windows folders or a NAS: `smb://` in Nautilus, `mount.cifs`, and `smbclient`; no server           |
| `ssh`            | sshd policy and its banner                                                                                                                          |
| `tailscale`      | Installed but not enabled                                                                                                                           |
| `terminal`       | fish, ghostty, and fastfetch                                                                                                                        |
| `updates`        | The signature policy for updates and the dev container, and a masked auto-update timer                                                              |
| `virtualization` | QEMU/KVM, libvirt, and Virtual Machine Manager                                                                                                      |
| `xrdp`           | Remote desktop on port 3389                                                                                                                         |
