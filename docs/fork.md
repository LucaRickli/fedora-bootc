# Create your own fork

You need `sbctl`, `cosign`, and the tools in
[Build the images](../README.md#build-the-images). A sealed build in CI needs
50 GB of free disk space, and GitHub-hosted runners for public repositories
have about 90 GB. Follow these steps:

1. Fork the repository, clone your fork, and replace the owner name everywhere
   except `LICENSE`, whose copyright notice must stay:

   ```sh
   git grep -l lucarickli -- ':!LICENSE' | xargs sed -i 's/lucarickli/GITHUB_OWNER/g'
   ```

   Replace `GITHUB_OWNER` with your lowercase username or organization name.

2. Replace the signing keys with your own:

   ```sh
   git rm -r keys/GUID keys/PK keys/KEK keys/db keys/cosign.pub
   just keygen          # Secure Boot keys, with sbctl
   just cosign-keygen   # Image signing key pair
   ```

   The recipes keep the public and private halves apart:

   ```mermaid
   flowchart LR
       gen["just keygen<br/>just cosign-keygen"] --> pubkeys["keys/<br/>certificates, GUID, cosign.pub"]
       gen --> keydir["Key directory<br/>private keys"]
       pubkeys -- "built into" --> images["Every image"]
       keydir -- "four secrets" --> relenv["release environment"]
       relenv -- "main and release tags" --> jobs["CI build and<br/>sign jobs"]
       jobs -- "sign" --> images
   ```

   Back up the [key directory](../keys/README.md#key-locations),
   `~/.local/share/fedora-bootc/keys` by default.

3. In **Settings** > **Environments**, create a `release` environment, and
   limit its **Deployment branches and tags** to `main` and the tags of
   releases you publish by hand. Add these environment secrets, each with the
   contents of its file in the key directory:

   - `SECUREBOOT_PRIVATE_KEY`: `db/db.key`
   - `SECUREBOOT_PK_PRIVATE_KEY`: `PK/PK.key`
   - `SECUREBOOT_KEK_PRIVATE_KEY`: `KEK/KEK.key`
   - `SIGNING_SECRET`: `cosign.key`

4. Change these settings:

   - In **Settings** > **General**, select **Allow auto-merge**.
   - In **Settings** > **Rulesets**, click **New ruleset** > **Import a
     ruleset**, and import
     [`.github/rulesets/main.json`](../.github/rulesets/main.json). Renovate's
     automatic merges then wait for the `ci-ok` check, which repository admins
     can bypass.
   - In **Settings** > **Advanced Security**, enable **Private vulnerability
     reporting** for the [Security policy](../SECURITY.md).

   GitHub can't assign an organization, so if one owns your fork, put a
   member's username in these places:

   - `ASSIGNEE` in [`.github/workflows/alerts.yml`](../.github/workflows/alerts.yml)
   - `OWNER` in [`.github/workflows/notify.yml`](../.github/workflows/notify.yml)
   - `OWNER` in the `security` job of
     [`.github/workflows/release.yml`](../.github/workflows/release.yml)
   - `assignees` and `reviewers` in [`renovate.json`](../renovate.json)

5. On the **Actions** tab, enable the workflows. GitHub disables scheduled
   workflows on a fork. Then commit all your changes, `keys/` included, and
   push them to `main`.

6. After the first build, make the `fedora-bootc` package public: in its
   **Package settings**, click **Change visibility**. If another repository
   pushed the package first, give your fork the **Write** role in
   **Manage Actions access**, or **Admin** to let CI delete old builds.

7. To publish the live ISO and the tags machines follow, run the release
   workflow once: **Actions** > **release** > **Run workflow**.
