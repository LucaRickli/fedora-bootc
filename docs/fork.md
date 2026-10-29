# Make it yours

To build and publish your own copy. Needs rootless `podman`, `just`,
`sbctl` and `cosign`, plus [`bcvk`](https://github.com/bootc-dev/bcvk),
`qemu` and OVMF for VM tests (Arch's or Fedora's edk2-ovmf).

1. Fork and point everything at your fork:

   ```sh
   git grep -il lucarickli | xargs sed -i \
     -e 's/lucarickli/<you, lowercase>/g'
   ```

2. Replace the keys with your own: the certificates and the public key go
   into `keys/` (commit them), the private keys into the key directory
   `~/.local/share/fedora-bootc/keys` (back it up,
   [keys/README.md](../keys/README.md)):

   ```sh
   git rm -r keys/GUID keys/PK keys/KEK keys/db keys/cosign.pub
   just keygen          # Secure Boot PK/KEK/db (sbctl)
   just cosign-keygen   # image signing key pair
   ```

3. Create the environment `release` (Settings, Environments), limit its
   deployment branches to `main` and, for a release published by hand, the
   release tags, and add four secrets to it, from the key directory:
   `SECUREBOOT_PRIVATE_KEY` (`db/db.key`), `SECUREBOOT_PK_PRIVATE_KEY`
   (`PK/PK.key`), `SECUREBOOT_KEK_PRIVATE_KEY` (`KEK/KEK.key`), which sign
   the enrollment sets, and `SIGNING_SECRET` (`cosign.key`). Only the jobs
   that declare that environment read them, so no workflow on another
   branch can. Repository secrets of those names work too, without that
   limit.
4. CI runs on GitHub's free hosted runners (`ubuntu-26.04`, rootless podman);
   nothing to install. A public repository gets the ~90 GB of disk a sealed
   build needs. In the repository settings: allow auto-merge, and import
   [`.github/rulesets/main.json`](../.github/rulesets/main.json) (Rules,
   Rulesets, New ruleset, Import a ruleset). It requires the `ci-ok` check
   from GitHub Actions before anything merges into `main`, so Renovate's
   automerge waits for the whole build ([updates.md](architecture/updates.md)), and lets
   repository admins bypass it, so you can still push to `main` directly.
   Under Code security, turn on private vulnerability reporting, which
   `SECURITY.md` points reporters at. The code scanning alerts and the
   issues CI opens go to the repository owner; an organisation cannot be
   assigned, so name a member as `ASSIGNEE` in `alerts.yml` and as `OWNER`
   in `notify.yml` and the `security` job of `release.yml` then.
5. After the first push, make the GHCR packages public. If a package already
   exists (pushed from another repository), grant this one access in the
   package settings (Manage Actions access: Write, or Admin so that CI can
   delete old builds).
6. Run the release workflow once (Actions, release): builds only push
   `build-<sha>` tags, the release publishes the ISO and the tags machines
   follow.
