# keys/

- **Secure Boot** (PK/KEK/db, `just keygen`): the db key signs systemd-boot,
  the UKI and the NVIDIA modules; the PK and KEK keys sign the enrollment
  sets every image carries (`PK.auth`, `KEK.auth`, `db.auth`,
  [`image/enroll.sh`](../image/enroll.sh)), which a machine enrolls from
  systemd-boot's menu ([docs/secureboot-tpm2.md](../docs/secureboot-tpm2.md)).
- **Microsoft's Secure Boot certificates** (`keys/microsoft/`): what the
  `fedora-bootc-and-microsoft` set adds to KEK and db, Microsoft's files as
  published ([microsoft/README.md](microsoft/README.md)).
- **Image signing** (cosign, `just cosign-keygen`): CI signs every image it
  pushes, the devtools repository's CI the dev container and the VS Code
  Flatpak, and the machine verifies its updates and the dev container
  against `cosign.pub` (`features/updates/overlay/etc/containers/policy.json`).

The public halves live here, committed. The private keys live outside the
checkout, in the key directory `~/.local/share/fedora-bootc/keys`
(`$XDG_DATA_HOME/fedora-bootc/keys`, or the directory `FEDORA_BOOTC_KEYS`
names), in the same layout, next to copies of the GUID and the certificates
(sbctl's own layout, which `just keygen` creates).

```text
keys/GUID             owner GUID                      committed  (the build needs it)
keys/PK/PK.pem        platform key certificate        committed  (the build needs it)
keys/KEK/KEK.pem      key-exchange certificate        committed  (the build needs it)
keys/db/db.pem        signature-db certificate        committed  (the build needs it)
keys/microsoft/       Microsoft's KEK and db certs    committed  (the build needs them)
keys/cosign.pub       image-signing public key        committed  (baked into the image)

<key dir>/PK/PK.key   PRIVATE keys                    never in the checkout
<key dir>/KEK/KEK.key                                 (the build needs PK, KEK and db)
<key dir>/db/db.key
<key dir>/cosign.key
<key dir>/GUID        copies of keys/GUID and keys/*/*.pem, for sbctl
<key dir>/*/*.pem
```

A build reads `db.key` and `keys/db/db.pem` as podman secrets in the three
steps that sign what boots, and `PK.key` and `KEK.key` with their
certificates (and `db.pem`, which goes into `db.auth`) in the one step that
signs the enrollment sets, the `enroll` stage of `build-base`, and nowhere
else; `SECUREBOOT_KEY` and `SECUREBOOT_CERT`, `SECUREBOOT_PK_KEY`
and `SECUREBOOT_PK_CERT`, `SECUREBOOT_KEK_KEY` and `SECUREBOOT_KEK_CERT` name
other files (CI: copies outside the checkout, a pull request's throwaway
tree). A key is always a file, never an environment secret. The checkout's
`keys/` is kept out of the build context except `cosign.pub` and
`microsoft/`'s certificates. CI needs `db.key`, `PK.key`, `KEK.key` and `cosign.key` as the
secrets of its `release` environment, `SECUREBOOT_PRIVATE_KEY`,
`SECUREBOOT_PK_PRIVATE_KEY`, `SECUREBOOT_KEK_PRIVATE_KEY` and
`SIGNING_SECRET` ([docs/fork.md](../docs/fork.md), Make it yours). The PK and
KEK keys can replace what every enrolled machine trusts, the db key only
add to what boots; all three are as safe as that environment.

Back up the key directory: `PK/PK.key`, `KEK/KEK.key`, `db/db.key` and
`cosign.key`. A new Secure Boot key means enrolling every machine again,
and a new db key a few steps more, one machine at a time, since an image
signed with it does not start where the old one is enforced
([docs/secureboot-tpm2.md](../docs/secureboot-tpm2.md#new-keys)). A new
cosign key is rejected by machines that still trust the old one, so rotate
in two steps: one update signed with the OLD key that carries the NEW public
key, then sign with the new key. The devtools repository signs the dev
container with the same key, so its `keys/cosign.pub` and `SIGNING_SECRET`
change in the same second step, and a run of its devcontainer workflow by
hand signs the dev container with the new key without waiting for Monday.
