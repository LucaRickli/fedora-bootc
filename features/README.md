# Features

Each folder in `features/` is one feature of the OS, with these optional files,
in build order:

| File              | What it is                                                                                                                                                                                    |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build.sh`        | Builds what Fedora doesn't package, from pinned upstream sources and the files next to it, in a throwaway stage ([`image/builds.sh`](../image/builds.sh))                                     |
| `pre-install.sh`  | What `packages.txt` can't express, such as a repository from a release package                                                                                                                |
| `packages.txt`    | RPMs to install, one per line, with `#` for comments; all features share one dnf transaction ([`image/packages.sh`](../image/packages.sh))                                                    |
| `exclude.txt`     | RPMs to keep out, such as weak dependencies that duplicate another                                                                                                                            |
| `post-install.sh` | What must happen in the transaction's layer, such as removing keys a package generated                                                                                                        |
| `overlay/`        | Files copied verbatim onto the image; no two features can ship the same path                                                                                                                  |
| `setup.sh`        | Build-time setup, then the checks that prove it and what it needs from other features, after a `# --- Checks` marker; runs in folder name order ([`image/finalize.sh`](../image/finalize.sh)) |

RPMs a `build.sh` leaves in `$OUT/rpm` join the package transaction; files in
`$OUT/root` land on the image.

A feature that enables or disables services ships
`overlay/usr/lib/systemd/system-preset/80-fedora-bootc-FEATURE.preset`, or the
same file in `user-preset/`, where `FEATURE` is the folder name.

Adding a feature, a package, or a build needs no change outside its folder.
[`image/features.sh`](../image/features.sh) checks each feature's files in
every build and in `just check`. To remove a feature, delete its folder. A
feature that relies on it then fails its checks. For what only some machines
need, see [Extras](../extras/README.md).

Some features are also used outside `features/`:

- `boot`: [`image/bootloader.sh`](../image/bootloader.sh) relies on its install
  configuration and kernel arguments.
- `locale`: [`installer/configure-installer.sh`](../installer/configure-installer.sh)
  sets the same keyboard layout for the LUKS passphrase, so change both
  together.
- `updates`: [`installer/live.Containerfile`](../installer/live.Containerfile)
  copies its signature policy.

The OS has these features:

| Feature          | What it provides                                                                                                                                    |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base`           | Command-line basics, such as git and the GitHub CLI, and account defaults, such as fish and `/var/home`                                             |
| `boot`           | bootc install configuration and kernel arguments, LUKS, quiet boot, a hidden boot menu, and Secure Boot enrollment sets on the EFI system partition |
| `cockpit`        | Cockpit web console, off by default, on loopback only                                                                                               |
| `containers`     | Docker next to podman, and the podman API socket                                                                                                    |
| `desktop`        | The Noctalia shell, portals, keyring, SSH agent, file manager, audio, and dark mode                                                                 |
| `fail2ban`       | Bans hosts after repeated login failures on SSH and XRDP                                                                                            |
| `flatpak`        | Flatpak with the Flathub and Devolutions remotes                                                                                                    |
| `llm`            | shimmy, a local LLM server, off by default; see [Local LLM](../docs/os.md#local-llm)                                                                |
| `locale`         | Time zone and keyboard layout for the console, X11, and Wayland                                                                                     |
| `login`          | greetd and noctalia-greeter, which `build.sh` builds from source                                                                                    |
| `sessions`       | niri, labwc, sway, river, and wayfire, set up for Noctalia                                                                                          |
| `smb`            | SMB client for shares on other machines, such as Windows folders or a NAS: `smb://` in Nautilus, `mount.cifs`, and `smbclient`; no server           |
| `ssh`            | sshd policy and its banner                                                                                                                          |
| `tailscale`      | Installed but not enabled                                                                                                                           |
| `terminal`       | fish, ghostty, and fastfetch                                                                                                                        |
| `updates`        | The signature policy for updates and the dev container, and a masked auto-update timer                                                              |
| `virtualization` | QEMU/KVM, libvirt, and Virtual Machine Manager                                                                                                      |
| `xrdp`           | Remote desktop on port 3389                                                                                                                         |
